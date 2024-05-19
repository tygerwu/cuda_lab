#include "cute/tensor.hpp"
#include "gtest/gtest.h"
#include "utils.h"

using namespace cute;

TEST(cute,iden_1){
    using BM = _8;
    using BK = _32; 
    using TK = Int<int(BK{} / 8)>;
    using TO = Int<int(32 / TK{})>;
    using M  = Int<15>;
    using K  = _32;
    // Padded M
    using PM = _16; 
    using PK = _32;

    using T = uint16_t;

    auto thr_layout = Layout<Shape<TO,TK>,Stride<TK,_1>>{};
    auto val_layout = Layout<Shape<_1,_8>,Stride<_1,_1>>{};

    using Vec = cutlass::AlignedArray<T,8>;

    auto tiled_copy = make_tiled_copy(Copy_Atom<UniversalCopy<Vec>,T>{},thr_layout,val_layout);

    std::vector<T> gmem_data(PM{} * K{});
    auto packed_gmem_layout = Layout<Shape<PM,PK>,Stride<PK,_1>>{};
    auto gmem = make_tensor(gmem_data.data(),packed_gmem_layout);

    int tid = 28;
    auto thr_copy = tiled_copy.get_slice(tid);
    auto g2s_src  = thr_copy.partition_S(gmem);


    auto identity = make_identity_tensor(Shape<PM,PK>{});
    auto g2s_iden = thr_copy.partition_S(identity); 

    int M_TiledCopy_ValTile = size<1>(g2s_src);
    int K_TiledCopy_ValTile = size<2>(g2s_src);
    auto pred_data = std::vector<int>(M_TiledCopy_ValTile*K_TiledCopy_ValTile,1);
    auto g2s_pred = make_tensor(pred_data.data(),
                                make_shape(M_TiledCopy_ValTile,K_TiledCopy_ValTile),
                                make_stride(1,0));

    for(int i=0;i<M_TiledCopy_ValTile;i++){
        if(get<0>(g2s_iden(0,i,0)) >= M{}){
            g2s_pred(i,0) = false;
        }
    }

    PrintIden("g2s_iden:",g2s_iden);
    Print("g2s_iden(8):",g2s_iden(8));
    PrintIden("g2s_iden layout:",layout(g2s_iden));
}


TEST(cute,iden_2){
    auto a  = Layout<Shape<_4,_8>,Stride<_1,_4>>{};
    auto b  = Layout<Shape<_4,_8>,Stride<_4,_5>>{};
    auto x  =  Layout<Shape<_4,_8>,Stride<_1,_1>>{};
    auto id = make_identity_layout(Shape<_4,_8>{});

    auto tile = make_tile(_2{},_4{});

    auto c0 = zipped_divide(id,tile);
    auto c1 = zipped_divide(x,tile);
    auto c2 = zipped_divide(a,tile);
    auto c3 = zipped_divide(b,tile);

    Print("c0",c0);
    Print("c1",c1);
    Print("c2",c2);
    Print("c3",c3);
}

TEST(cute,iden_3){
    auto shape = make_shape(2,make_shape(3,make_shape(4,5)));
    auto layout = make_layout(shape,make_basis_like(shape));
    Print("layout:",layout);
}