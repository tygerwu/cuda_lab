#include "assert.h"
#include <stdio.h>
#include <stdlib.h>
// CUDA runtime
#include <cuda_runtime.h>

// cal offset from row col and ld , in row-major matrix, ld is the width of the
// matrix
#define OFFSET(row, col, ld) ((row) * (ld) + (col))

// transfer float4
#define FETCH_FLOAT4(pointer) (reinterpret_cast<float4 *>(&(pointer))[0])
#define CONST_FETCH_FLOAT4(pointer)                                            \
  (reinterpret_cast<const float4 *>(&(pointer))[0])

#define checkCudaErrors(func)                                                  \
  {                                                                            \
    cudaError_t e = (func);                                                    \
    if (e != cudaSuccess)                                                      \
      printf("%s %d CUDA: %s\n", __FILE__, __LINE__, cudaGetErrorString(e));   \
  }

// K: ldA
// N: ldB
template <
    const int BLOCK_SIZE_M,  // height of block of C that each thread block
                             // calculate
    const int BLOCK_SIZE_K,  // width of block of A that each thread block load
                             // into shared memory
    const int BLOCK_SIZE_N,  // width of block of C that each thread block
                             // calculate
    const int THREAD_SIZE_Y, // height of block of C that each thread calculate
    const int THREAD_SIZE_X, // width of block of C that each thread calculate
    const bool ENABLE_DOUBLE_BUFFER // whether enable double buffering or not
    >
static __global__ void SGemmV3Impl(const float *__restrict__ A,
                                   const float *__restrict__ B,
                                   float *__restrict__ C, int M, int N, int K) {
  // Block index
  int bx = blockIdx.x;
  int by = blockIdx.y;

  // Thread index
  int tx = threadIdx.x;
  int ty = threadIdx.y;

  // the threads number in Block of X,Y
  const int THREAD_X_PER_BLOCK = BLOCK_SIZE_N / THREAD_SIZE_X;
  const int THREAD_Y_PER_BLOCK = BLOCK_SIZE_M / THREAD_SIZE_Y;
  const int THREAD_NUM_PER_BLOCK = THREAD_X_PER_BLOCK * THREAD_Y_PER_BLOCK;

  // thread id in cur Block
  const int tid = ty * THREAD_X_PER_BLOCK + tx;

  // shared memory
  __shared__ float As[2][BLOCK_SIZE_K][BLOCK_SIZE_M];
  __shared__ float Bs[2][BLOCK_SIZE_K][BLOCK_SIZE_N];
  // registers for C
  float accum[THREAD_SIZE_Y][THREAD_SIZE_X];
#pragma unroll
  for (int i = 0; i < THREAD_SIZE_Y; i++) {
#pragma unroll
    for (int j = 0; j < THREAD_SIZE_X; j++) {
      accum[i][j] = 0.0;
    }
  }
  // registers for A and B
  float frag_a[2][THREAD_SIZE_Y];
  float frag_b[2][THREAD_SIZE_X];
  // registers load global memory
  // MC*KC / (TMN * 4)
  const int ldg_num_a =
      BLOCK_SIZE_M * BLOCK_SIZE_K / (THREAD_NUM_PER_BLOCK * 4);
  const int ldg_num_b =
      BLOCK_SIZE_K * BLOCK_SIZE_N / (THREAD_NUM_PER_BLOCK * 4);
  float ldg_a_reg[4 * ldg_num_a];
  float ldg_b_reg[4 * ldg_num_b];

  // threads number in one row
  const int A_TILE_THREAD_PER_ROW = BLOCK_SIZE_K / 4;
  const int B_TILE_THREAD_PER_ROW = BLOCK_SIZE_N / 4;

  // row number and col number that needs to be loaded by this thread
  const int A_TILE_ROW_START = tid / A_TILE_THREAD_PER_ROW;
  const int B_TILE_ROW_START = tid / B_TILE_THREAD_PER_ROW;

  const int A_TILE_COL = tid % A_TILE_THREAD_PER_ROW * 4;
  const int B_TILE_COL = tid % B_TILE_THREAD_PER_ROW * 4;

  // row stride that thread uses to load multiple rows of a tile
  const int A_TILE_ROW_STRIDE = THREAD_NUM_PER_BLOCK / A_TILE_THREAD_PER_ROW;
  const int B_TILE_ROW_STRIDE = THREAD_NUM_PER_BLOCK / B_TILE_THREAD_PER_ROW;

  A = &A[(BLOCK_SIZE_M * by) * K];
  B = &B[BLOCK_SIZE_N * bx];

  // load index of the tile
  const int warp_id = tid / 32;
  const int lane_id = tid % 32;
  const int a_tile_index =
      warp_id / 2 * 16 +
      lane_id / 8 * 4; // warp_id * 8 + (lane_id / 16)*4; //
                       // (warp_id/4)*32 + ((lane_id%16)/2)*4;
  const int b_tile_index =
      warp_id % 2 * 32 +
      lane_id % 8 * 4; //(lane_id % 16) * 4; // (warp_id%4)*16 + (lane_id/16)*8
                       //+ (lane_id%2)*4;

// transfer first tile from global mem to shared mem
// load A from global memory to shared memory
#pragma unroll
  // A_TILE_ROW_STRIDE : TMN / (KC / 4)
  for (int i = 0; i < BLOCK_SIZE_M; i += A_TILE_ROW_STRIDE) {
    int ldg_index = i / A_TILE_ROW_STRIDE * 4;
    FETCH_FLOAT4(ldg_a_reg[ldg_index]) =
        CONST_FETCH_FLOAT4(A[OFFSET(A_TILE_ROW_START + i, // row
                                    A_TILE_COL,           // col
                                    K)]);
    As[0][A_TILE_COL][A_TILE_ROW_START + i] = ldg_a_reg[ldg_index];
    As[0][A_TILE_COL + 1][A_TILE_ROW_START + i] = ldg_a_reg[ldg_index + 1];
    As[0][A_TILE_COL + 2][A_TILE_ROW_START + i] = ldg_a_reg[ldg_index + 2];
    As[0][A_TILE_COL + 3][A_TILE_ROW_START + i] = ldg_a_reg[ldg_index + 3];
  }
// load B from global memory to shared memory
#pragma unroll
  for (int i = 0; i < BLOCK_SIZE_K; i += B_TILE_ROW_STRIDE) {
    FETCH_FLOAT4(Bs[0][B_TILE_ROW_START + i][B_TILE_COL]) =
        CONST_FETCH_FLOAT4(B[OFFSET(B_TILE_ROW_START + i, // row
                                    B_TILE_COL,           // col
                                    N)]);
  }
  __syncthreads();

  // load A from shared memory to register
  FETCH_FLOAT4(frag_a[0][0]) = CONST_FETCH_FLOAT4(As[0][0][a_tile_index]);
  FETCH_FLOAT4(frag_a[0][4]) = CONST_FETCH_FLOAT4(As[0][0][a_tile_index + 64]);

  // load B from shared memory to register
  FETCH_FLOAT4(frag_b[0][0]) = CONST_FETCH_FLOAT4(Bs[0][0][b_tile_index]);
  FETCH_FLOAT4(frag_b[0][4]) = CONST_FETCH_FLOAT4(Bs[0][0][b_tile_index + 64]);

  int write_stage_idx = 1;
  int tile_idx = 0;
  do {
    // next tile index
    tile_idx += BLOCK_SIZE_K;
    // load next tile from global mem
    if (tile_idx < K) {
#pragma unroll
      for (int i = 0; i < BLOCK_SIZE_M; i += A_TILE_ROW_STRIDE) {
        int ldg_index = i / A_TILE_ROW_STRIDE * 4;
        FETCH_FLOAT4(ldg_a_reg[ldg_index]) =
            CONST_FETCH_FLOAT4(A[OFFSET(A_TILE_ROW_START + i,  // row
                                        A_TILE_COL + tile_idx, // col
                                        K)]);
      }
#pragma unroll
      for (int i = 0; i < BLOCK_SIZE_K; i += B_TILE_ROW_STRIDE) {
        int ldg_index = i / B_TILE_ROW_STRIDE * 4;
        FETCH_FLOAT4(ldg_b_reg[ldg_index]) =
            CONST_FETCH_FLOAT4(B[OFFSET(tile_idx + B_TILE_ROW_START + i, // row
                                        B_TILE_COL,                      // col
                                        N)]);
      }
    }

    int load_stage_idx = write_stage_idx ^ 1;

#pragma unroll
    for (int j = 0; j < BLOCK_SIZE_K - 1; ++j) {
      // load next tile from shared mem to register
      // load A from shared memory to register
      FETCH_FLOAT4(frag_a[(j + 1) % 2][0]) =
          CONST_FETCH_FLOAT4(As[load_stage_idx][(j + 1)][a_tile_index]);
      FETCH_FLOAT4(frag_a[(j + 1) % 2][4]) =
          CONST_FETCH_FLOAT4(As[load_stage_idx][(j + 1)][a_tile_index + 64]);
      // load B from shared memory to register
      FETCH_FLOAT4(frag_b[(j + 1) % 2][0]) =
          CONST_FETCH_FLOAT4(Bs[load_stage_idx][(j + 1)][b_tile_index]);
      FETCH_FLOAT4(frag_b[(j + 1) % 2][4]) =
          CONST_FETCH_FLOAT4(Bs[load_stage_idx][(j + 1)][b_tile_index + 64]);
// compute C THREAD_SIZE_X x THREAD_SIZE_Y
#pragma unroll
      for (int thread_y = 0; thread_y < THREAD_SIZE_Y; ++thread_y) {
#pragma unroll
        for (int thread_x = 0; thread_x < THREAD_SIZE_X; ++thread_x) {
          accum[thread_y][thread_x] +=
              frag_a[j % 2][thread_y] * frag_b[j % 2][thread_x];
        }
      }
    }

    if (tile_idx < K) {
// load A from global memory to shared memory
#pragma unroll
      for (int i = 0; i < BLOCK_SIZE_M; i += A_TILE_ROW_STRIDE) {
        int ldg_index = i / A_TILE_ROW_STRIDE * 4;
        As[write_stage_idx][A_TILE_COL][A_TILE_ROW_START + i] =
            ldg_a_reg[ldg_index];
        As[write_stage_idx][A_TILE_COL + 1][A_TILE_ROW_START + i] =
            ldg_a_reg[ldg_index + 1];
        As[write_stage_idx][A_TILE_COL + 2][A_TILE_ROW_START + i] =
            ldg_a_reg[ldg_index + 2];
        As[write_stage_idx][A_TILE_COL + 3][A_TILE_ROW_START + i] =
            ldg_a_reg[ldg_index + 3];
      }
// load B from global memory to shared memory
#pragma unroll
      for (int i = 0; i < BLOCK_SIZE_K; i += B_TILE_ROW_STRIDE) {
        int ldg_index = i / B_TILE_ROW_STRIDE * 4;
        FETCH_FLOAT4(Bs[write_stage_idx][B_TILE_ROW_START + i][B_TILE_COL]) =
            CONST_FETCH_FLOAT4(ldg_b_reg[ldg_index]);
      }
      // use double buffer, only need one sync
      __syncthreads();
      // switch
      write_stage_idx ^= 1;
    }

    // load first tile from shared mem to register of next iter
    // load A from shared memory to register
    FETCH_FLOAT4(frag_a[0][0]) =
        CONST_FETCH_FLOAT4(As[load_stage_idx ^ 1][0][a_tile_index]);
    FETCH_FLOAT4(frag_a[0][4]) =
        CONST_FETCH_FLOAT4(As[load_stage_idx ^ 1][0][a_tile_index + 64]);
    // load B from shared memory to register
    FETCH_FLOAT4(frag_b[0][0]) =
        CONST_FETCH_FLOAT4(Bs[load_stage_idx ^ 1][0][b_tile_index]);
    FETCH_FLOAT4(frag_b[0][4]) =
        CONST_FETCH_FLOAT4(Bs[load_stage_idx ^ 1][0][b_tile_index + 64]);
// compute C THREAD_SIZE_X x THREAD_SIZE_Y
#pragma unroll
    for (int thread_y = 0; thread_y < THREAD_SIZE_Y; ++thread_y) {
#pragma unroll
      for (int thread_x = 0; thread_x < THREAD_SIZE_X; ++thread_x) {
        accum[thread_y][thread_x] += frag_a[1][thread_y] * frag_b[1][thread_x];
      }
    }
  } while (tile_idx < K);

  const int c_block_row = a_tile_index;
  const int c_block_col = b_tile_index;

  // store C00 block
  for (int i = 0; i < 4; i++) {
    FETCH_FLOAT4(C[OFFSET(BLOCK_SIZE_M * by + c_block_row + i,
                          BLOCK_SIZE_N * bx + c_block_col, N)]) =
        CONST_FETCH_FLOAT4(accum[i][0]);
  }
  // store C01 block
  for (int i = 0; i < 4; i++) {
    FETCH_FLOAT4(C[OFFSET(BLOCK_SIZE_M * by + c_block_row + i,
                          BLOCK_SIZE_N * bx + c_block_col + 64, N)]) =
        CONST_FETCH_FLOAT4(accum[i][4]);
  }
  // store C10 block
  for (int i = 0; i < 4; i++) {
    FETCH_FLOAT4(C[OFFSET(BLOCK_SIZE_M * by + c_block_row + 64 + i,
                          BLOCK_SIZE_N * bx + c_block_col, N)]) =
        CONST_FETCH_FLOAT4(accum[i + 4][0]);
  }
  // store C11 block
  for (int i = 0; i < 4; i++) {
    FETCH_FLOAT4(C[OFFSET(BLOCK_SIZE_M * by + c_block_row + 64 + i,
                          BLOCK_SIZE_N * bx + c_block_col + 64, N)]) =
        CONST_FETCH_FLOAT4(accum[i + 4][4]);
  }
}

template <
    const int BLOCK_SIZE_M,  // height of block of C that each thread block
                             // calculate
    const int BLOCK_SIZE_K,  // width of block of A that each thread block load
                             // into shared memory
    const int BLOCK_SIZE_N,  // width of block of C that each thread block
                             // calculate
    const int THREAD_SIZE_Y, // height of block of C that each thread calculate
    const int THREAD_SIZE_X, // width of block of C that each thread calculate
    const bool ENABLE_DOUBLE_BUFFER = false // whether enable double buffering
                                            // or not
    >
static void SGemmV3(const float *A, const float *B, float *C, int M, int N,
                    int K) {
  dim3 dimBlock(BLOCK_SIZE_N / THREAD_SIZE_X, BLOCK_SIZE_M / THREAD_SIZE_Y);
  dim3 dimGrid(N / BLOCK_SIZE_N, M / BLOCK_SIZE_M);
  SGemmV3Impl<BLOCK_SIZE_M, BLOCK_SIZE_K, BLOCK_SIZE_N, THREAD_SIZE_Y,
              THREAD_SIZE_X, ENABLE_DOUBLE_BUFFER>
      <<<dimGrid, dimBlock>>>(A, B, C, M, N, K);
}