
#pragma once
#include "utils.cuh"
#include "utils.h"
#include <cuda_runtime.h>

#include <stdio.h>
template <size_t MC, size_t KC, size_t NC, size_t MR, size_t NR, size_t WY,
          size_t WX>
static __global__ void
CudaSGemmMacroBufferImpl(const float *__restrict__ A,
                         const float *__restrict__ B, float *__restrict__ C,
                         int M, int N, int K, int ldk, int ldn) {

  static_assert(MR % 4 == 0, "Invalid MR");
  static_assert(NR % 4 == 0, "Invalid NR");
  static_assert(NC % (WX * NR) == 0, "Invalid NC");
  static_assert(MC % (WY * MR) == 0, "Invalid MC");
  static_assert(KC % 4 == 0, "Invalid KC");

  constexpr size_t TX = NC / NR;
  constexpr size_t TY = MC / MR;
  constexpr size_t TXY = TX * TY;
  static_assert(TXY % WARP_SIZE == 0, "Invalid ThreadBlock");

  int tid_x = threadIdx.x;
  int tid_y = threadIdx.y;
  int tid = tid_y * blockDim.x + tid_x;

  int bid_x = blockIdx.x;
  int bid_y = blockIdx.y;

  int wid_x = tid_x / WX;
  int wid_y = tid_y / WY;
  int tid_x_in_w = tid_x % WX;
  int tid_y_in_w = tid_y % WY;

  // SMem
  constexpr size_t A_PAD = 4;
  constexpr size_t A_MICRO_SIZE = UP_ROUND(MR * KC, 32) + A_PAD;
  constexpr size_t A_WARP_MICRO_SIZE = WY * A_MICRO_SIZE;
  constexpr size_t A_MICRO_NUM = MC / MR;
  constexpr size_t A_MACRO_SMEM_SIZE = A_MICRO_NUM * A_MICRO_SIZE + 4;

  constexpr size_t B_PAD = 4;
  constexpr size_t B_MICRO_SIZE = UP_ROUND(KC * NR, 32) + B_PAD;
  constexpr size_t B_WARP_MICRO_SIZE = WX * B_MICRO_SIZE;
  constexpr size_t B_MICRO_NUM = NC / NR;
  constexpr size_t B_MACRO_SMEM_SIZE = B_MICRO_NUM * B_MICRO_SIZE + 4;

  __shared__ float a_macro_smem[2 * A_MACRO_SMEM_SIZE];
  __shared__ float b_macro_smem[2 * B_MACRO_SMEM_SIZE];

  // Regs
  float a_regs[MR];
  float b_regs[NR];
  float c_acc_regs[MR * NR] = {0};

  constexpr size_t B_MACRO_F4_NUM = KC * NC / 4;
  constexpr size_t NC_F4_NUM = NC / 4;
  constexpr size_t NR_F4_NUM = NR / 4;

  constexpr size_t A_MACRO_F4_NUM = MC * KC / 4;
  constexpr size_t KC_F4_NUM = KC / 4;

  auto LoadFromGMem = [A, B, tid, bid_x, bid_y, ldk, ldn](int buf_id, int pc) {
    // Load AMacroBlock from GMem to SMem
    const float *a_macro_gmem = A + bid_y * MC * ldk + pc;

#pragma unroll
    for (int i = 0; i < A_MACRO_F4_NUM; i += TXY) {
      int t_f4_id = i + tid;
      if (t_f4_id < A_MACRO_F4_NUM) {
        int y = t_f4_id / KC_F4_NUM;
        int x = t_f4_id % KC_F4_NUM;
        int mr_id = y / MR;
        int mr_offset = y % MR;
        float4 tmp = *CONST_FP4_PTR(a_macro_gmem + y * ldk + x * 4);

        float *ptr = a_macro_smem + buf_id * A_MACRO_SMEM_SIZE +
                     mr_id * A_MICRO_SIZE + (x * 4) * MR + mr_offset;
        *(ptr) = tmp.x;
        *(ptr + MR) = tmp.y;
        *(ptr + 2 * MR) = tmp.z;
        *(ptr + 3 * MR) = tmp.w;
      }
    }

    // Load BMacroBlock from GMem to SMem
    const float *b_macro_gmem = B + pc * ldn + bid_x * NC;

#pragma unroll
    for (int i = 0; i < B_MACRO_F4_NUM; i += TXY) {
      int t_f4_id = i + tid;
      if (t_f4_id < B_MACRO_F4_NUM) {

        int y = t_f4_id / NC_F4_NUM;
        int x = t_f4_id % NC_F4_NUM;
        int nr_id = x / NR_F4_NUM;
        int nr_offset = x % NR_F4_NUM;

        *FP4_PTR(b_macro_smem + buf_id * B_MACRO_SMEM_SIZE +
                 nr_id * B_MICRO_SIZE + y * NR + nr_offset * 4) =
            *CONST_FP4_PTR(b_macro_gmem + y * ldn + x * 4);
      }
    }
  };

  auto MicroKernel = [&a_regs, &b_regs, &c_acc_regs, wid_x, wid_y, tid_x_in_w,
                      tid_y_in_w](int buf_id) {
#pragma unroll
    for (int p = 0; p < KC; p++) {
#pragma unroll
      for (int i = 0; i < NR; i += 4) {
        *FP4_PTR(b_regs + i) = *CONST_FP4_PTR(
            b_macro_smem + buf_id * B_MACRO_SMEM_SIZE +
            wid_x * B_WARP_MICRO_SIZE + tid_x_in_w * B_MICRO_SIZE + p * NR + i);
      }
#pragma unroll
      for (int i = 0; i < MR; i += 4) {
        *FP4_PTR(a_regs + i) = *CONST_FP4_PTR(
            a_macro_smem + buf_id * A_MACRO_SMEM_SIZE +
            wid_y * A_WARP_MICRO_SIZE + tid_y_in_w * A_MICRO_SIZE + p * MR + i);
      }
#pragma unroll
      for (int i = 0; i < MR; i++) {
#pragma unroll
        for (int j = 0; j < NR; j++) {
          c_acc_regs[i * NR + j] += a_regs[i] * b_regs[j];
        }
      }
    }
  };
  LoadFromGMem(0, 0);
  int pk = KC;
  for (; pk < K;) {
    if (pk + KC <= K) {
      __syncthreads();
      LoadFromGMem(1, pk);
      MicroKernel(0);
      pk += KC;
    }

    if (pk + KC <= K) {
      __syncthreads();
      LoadFromGMem(0, pk);
      MicroKernel(1);
      pk += KC;
    }
  }
  __syncthreads();
  if ((K / KC) % 2 == 0) {
    MicroKernel(1);
  } else {
    MicroKernel(0);
  }

  // Store C
  float *c_macro_gmem = C + bid_y * MC * ldn + bid_x * NC;
  for (int i = 0; i < MR; i++) {
    for (int j = 0; j < NR; j++) {
      // py: tid_y * MR + i
      // px: tid_x * NR + j
      c_macro_gmem[(tid_y * MR + i) * ldn + tid_x * NR + j] =
          c_acc_regs[i * NR + j];
    }
  }
}

template <size_t MC, size_t KC, size_t NC, size_t MR, size_t NR, size_t WY,
          size_t WX>
static void CudaSGemmMacroBuffer(const float *A, const float *B, float *C,
                                 int M, int N, int K) {
  dim3 dimBlock(NC / NR, MC / MR);
  dim3 dimGrid(N / NC, M / MC);
  CudaSGemmMacroBufferImpl<MC, KC, NC, MR, NR, WY, WX>
      <<<dimGrid, dimBlock>>>(A, B, C, M, N, K, K, N);
}