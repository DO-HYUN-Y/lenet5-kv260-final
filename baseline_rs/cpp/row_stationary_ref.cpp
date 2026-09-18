#include <algorithm>
#include <cstdint>
#include <vector>

// Standalone numerical mirror of M8/R128 RS. This is a software model,
// not a cycle simulation or a substitute for the synthesized SA.
extern "C" int alexnet_row_stationary_layer(
    const std::int8_t* source_n8, const std::int8_t* weights_nk,
    const std::int32_t* bias, const std::int32_t* multiplier,
    const std::uint8_t* shift, int relu, int layer,
    std::int8_t* output_n8, std::int32_t* accum_n8,
    std::uint64_t* counters) {
  if (!source_n8 || !weights_nk || !bias || !multiplier || !shift ||
      !output_n8 || !accum_n8 || !counters || layer < 1 || layer > 8) return -1;
  const int hs[] = {224,27,13,13,13,6,1,1};
  const int cs[] = {3,64,192,384,256,256,4096,4096};
  const int ns[] = {64,192,384,256,256,4096,4096,1000};
  const int ks[] = {11,5,3,3,3,1,1,1};
  const int os[] = {55,27,13,13,13,1,1,1};
  const int st[] = {4,1,1,1,1,1,1,1};
  const int pd[] = {2,2,1,1,1,0,0,0};
  const int i = layer-1, h = hs[i], c = cs[i], n = ns[i], out = os[i];
  const int mtotal = out*out;
  const int ktotal = layer <= 5 ? c*ks[i]*ks[i] : layer == 6 ? 9216 : 4096;
  std::uint64_t macs=0, inputs=0, weights=0, commands=0, tiles=0;
  const int rw=layer<=5?ks[i]:layer==6?6:1;
  const int block=128*rw;
  for (int mb=0; mb<mtotal;) {
    const int mc=std::min(8,out-mb%out);
    std::vector<std::int32_t> scratch(mc*n,0);
    std::int8_t resident[8][1408]{};
    for (int ko=0; ko<ktotal; ko+=block) {
      const int kc=std::min(block,ktotal-ko);
      for (int m=0; m<mc; ++m) for (int k=0; k<kc; ++k) {
        const int absolute=ko+k;
        std::int8_t value=0;
        if (layer<=5) {
          const int row=absolute/rw, channel=row%c;
          const int ky=row/c, kx=absolute%rw;
          const int y=((mb+m)/out)*st[i]+ky-pd[i];
          const int x=((mb+m)%out)*st[i]+kx-pd[i];
          if (y>=0 && x>=0 && y<h && x<h)
            value=source_n8[((channel/8)*h*h+y*h+x)*8+channel%8];
        } else if (layer==6) {
          const int channel=absolute/36, position=absolute%36;
          value=source_n8[((channel/8)*36+position)*8+channel%8];
        } else value=source_n8[absolute];
        resident[m][k]=value;
      }
      inputs+=mc*kc; ++tiles;
      for (int nb=0; nb<n; nb+=8) {
        const int nc=std::min(8,n-nb); ++commands;
        for (int nl=0; nl<nc; ++nl) {
          const int nn=nb+nl;
          const auto* w=weights_nk+nn*ktotal+ko;
          weights+=kc;
          for (int m=0; m<mc; ++m) {
            // Local S-tap row sums, then the same 128-row spatial tree.
            std::int32_t row[128]{};
            for (int r=0;r<kc/rw;++r) for (int tap=0;tap<rw;++tap) {
              const int k=r*rw+tap;
              row[r]+=static_cast<std::int32_t>(resident[m][k])*w[k];
              if(row[r]<-(1<<18) || row[r]>=(1<<18)) return -2;
              ++macs;
            }
            int bits=20;
            for(int width=128;width>1;width/=2,++bits) for(int r=0;r<width/2;++r) {
              row[r]=row[2*r]+row[2*r+1];
              if(row[r]<-(1<<(bits-1)) || row[r]>=(1<<(bits-1))) return -2;
            }
            scratch[m*n+nn]+=row[0];
            if(scratch[m*n+nn]<-(1<<26) || scratch[m*n+nn]>=(1<<26)) return -2;
          }
        }
      }
    }
    for (int m=0; m<mc; ++m) for (int nn=0; nn<n; ++nn) {
      const int offset=((nn/8)*mtotal+mb+m)*8+nn%8;
      const auto acc=scratch[m*n+nn]; accum_n8[offset]=acc;
      const std::int64_t biased=static_cast<std::int64_t>(acc)+bias[nn];
      if (biased<-(1<<26) || biased>=(1<<26) || multiplier[nn]<65540 ||
          multiplier[nn]>131067 || shift[nn]<23 || shift[nn]>32) return -3;
      const std::int64_t product=biased*multiplier[nn];
      const auto magnitude=static_cast<std::uint64_t>(product<0 ? -product : product);
      const auto rounded=shift[nn] ? (magnitude+(std::uint64_t{1}<<(shift[nn]-1)))>>shift[nn] : magnitude;
      std::int64_t value=product<0 ? -static_cast<std::int64_t>(rounded) : static_cast<std::int64_t>(rounded);
      if (relu && value<0) value=0;
      output_n8[offset]=static_cast<std::int8_t>(std::clamp<std::int64_t>(value,-128,127));
    }
    mb+=mc;
  }
  counters[0]=macs; counters[1]=inputs; counters[2]=weights;
  counters[3]=commands; counters[4]=tiles;
  return 0;
}
