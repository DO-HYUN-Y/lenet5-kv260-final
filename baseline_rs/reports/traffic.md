# Pure RS / hybrid traffic audit

executed RTL scheduler descriptors and independent RS gather-policy replay. Physical DDR has not been measured.

| Layer | RS weight B | Hybrid weight B | RS raw gather B |
|---|---:|---:|---:|
| conv1 | 8,944,320 | 23,232 | 1,281,056 |
| conv2 | 33,177,600 | 307,200 | 321,984 |
| conv3 | 17,252,352 | 663,552 | 106,560 |
| conv4 | 23,003,136 | 884,736 | 213,120 |
| conv5 | 15,335,424 | 589,824 | 142,080 |
| fc6 | 37,748,736 | 37,748,736 | 11,520 |
| fc7 | 16,777,216 | 16,777,216 | 4,096 |
| fc8 | 4,096,000 | 4,128,768 | 4,096 |

Weight component: RS 156,334,784 B, hybrid 61,123,264 B; hybrid reduction 60.90%.

The 16 KiB external psum scratch serves continuation on chip; no artificial psum DDR spill is counted.

Weight-component savings do not alone establish total physical DDR savings or speed.
RS has additional row register storage; DSP count and shared bank capacities are fixed, total FF/LUT area is reported separately.
Gather predictions describe RS row-buffer policy; no hybrid physical input-traffic measurement is claimed.
M tiles stop at output row boundaries; this increases RS Conv weight loads relative to cross-row M8 tiling.
