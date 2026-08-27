# AlexNet KV260 pre-RTL sign-off

Date: 2026-08-27 (Asia/Seoul)

## 결론

RTL 작성 전 software/architecture gate는 통과했다. RTL은 아직 작성하지 않았다.
첫 구현은 K26의 200 MHz 기준 logical `M32xN64` packed SA, local `M8xN8`
skew, RS activation feeder, OS PE accumulator, WS weight ping/pong 구조로 고정한다.
INT8 C++ golden은 최종 18-bit multiplier 계약으로 11개 network 경계가 모두
byte-exact이고, calibration과 분리된 5,000장에서 FP32 대비 INT8 Top-1 하락은
0.44 percentage point다.

## 재현 가능한 고정 입력

| 항목 | SHA-256 |
|---|---|
| torchvision checkpoint | `7be5be791159472b1fbf3c69796f7cb30dca7ad8466c2df70058c37116cdee02` |
| INT8 quantization contract | `1a85423e46a77b088703428b00292b14b6d86c1f835c697537305f04641207d0` |
| exported model manifest | `53b09c7a50a6b6cec317e12250bcb495aa0508809ea9510dc60d638748a76b7c` |
| calibration-disjoint 5,000 list | `96f9623a099efd48bcd99c64ef2b8bb2c34ce9e91e659187010b9cb158306af4` |
| ordered 5,000 image set | `50677ca17e6854d8253c7672ba38f18cfe2477533fd7ea9df8f7fda2934002f4` |
| class-balanced 1,000 profile list | `5b4556d82105db697d500db8c2779a132ddd9c91d85df06778f2039ab0ce9393` |
| 5,000-image accuracy report | `f08b2e34b3b530310449f4ef1061a567fd185ec49823c0593687ea2bbc616a9e` |
| 1,000-image range/sparsity report | `24f1fb8600c963cb5d9f7c1569a72e2ca595aff8132581227d8ab9cd632e1d7c` |
| final full-network parity report | `e26c4f00d440934ff4484410a025aafc4ca0c8186525ac1a916ae3aaf98c70f2` |

ImageNet image 자체와 61 MiB model/vector blob은 git에 넣지 않는다. 저장소에는
선택 list, contract, compact result만 두고 위 hash로 local artifact를 검증한다.

## 정확도 gate

5,000장은 MLCommons calibration 500장과 겹치지 않고, 1,000개 class마다
deterministic hash 순서의 5장을 선택했다.

| Model | Top-1 | Top-5 |
|---|---:|---:|
| FP32 pretrained | 56.10% (2,805/5,000) | 78.48% (3,924/5,000) |
| C++ INT8, multiplier s18 | 55.66% (2,783/5,000) | 78.82% (3,941/5,000) |

Top-1 prediction agreement는 93.60% (4,680/5,000)다. 같은 1,000장
slice에서 s32와 s18 multiplier는 INT8 Top-1이 561장으로 같았다. 전체 5,000장에서는
s18이 s32 후보보다 Top-1 3장, Top-5 6장 더 맞았으므로 DSP 입력 폭을 줄이는 선택에
정확도 손해가 없다. 공식 50,000장 평가는 board-release gate로 남긴다.

## Numeric ABI와 폭 증명

- activation/weight: symmetric signed INT8, numeric zero code `0`
- accumulation/storage ABI: checked signed INT32
- bias: signed INT32, scale 전에 더함
- post-bias multiplier input: signed 27-bit, runtime clip 금지
- multiplier: non-negative signed 18-bit, 범위 `65,540..131,067`
- product: exact signed 45-bit DSP48E2 `27x18`
- right shift: 23..32, round-half-away-from-zero
- ReLU: scale/round 뒤, INT8 saturation 전
- output: signed INT8 saturation `[-128,127]`

실측값으로만 폭을 줄이지 않았다. 고정 weight의 각 곱항에 가능한 activation
`[-128,127]` 최솟값/최댓값을 channel별로 합산한 all-input 정적 bound는 다음과 같다.

| Layer | All-input post-bias bound | Static bits | 1,000장 observed accumulator | Observed bits |
|---|---:|---:|---:|---:|
| Conv1 | -1,805,100..1,801,110 | 22 | -913,671..934,025 | 21 |
| Conv2 | -5,755,159..5,786,420 | 24 | -841,900..142,535 | 21 |
| Conv3 | -6,420,373..6,431,117 | 24 | -242,532..145,962 | 19 |
| Conv4 | -12,459,168..12,476,517 | 25 | -243,245..98,062 | 19 |
| Conv5 | -9,253,804..9,276,026 | 25 | -200,773..76,199 | 19 |
| FC6 | -56,555,046..56,622,879 | 27 | -729,899..414,164 | 21 |
| FC7 | -27,100,445..27,139,840 | 26 | -643,496..452,942 | 21 |
| FC8 | -13,591,467..13,587,963 | 25 | -77,598..167,596 | 19 |

## Compute와 postprocess 구조

```text
base tile: physical 4x8 packed PE = logical M8xN8 = 32 DSP
top array: 4 M-groups x 8 N-groups = logical M32xN64
compute DSP: 32 base tiles x 32 = 1,024
postprocess DSP: 64, N output-channel마다 1개
total target: 1,088 / 1,248 DSP48E2
peak at 200 MHz: 2,048 MAC/cycle = 0.819 TOPS (1 MAC = 2 OPS)
```

Skew는 전체 `M32xN64` wire를 runtime에 바꾸지 않는다. 각 `M8xN8` 안에서만
고정 delay를 사용하고 상위는 registered activation/weight broadcast tree다. Conv와
FC의 차이는 descriptor, loop bound, lane mask와 buffer address이고 배선은 동일하다.

64-lane postprocess는 같은 M 위치의 N64 결과를 한 cycle에 처리하여 2,048개 tile
결과를 32 cycle에 처리한다. 최소 compute 간격인 Conv1 K=363보다 충분히 짧다.
SA가 drain 동안 멈추지 않게
`reduce_last`에서 결과를 PE별 holding register로 snapshot하고 accumulator를 다음
tile에 즉시 clear한다. holding 결과가 비워지기 전 다음 `reduce_last`가 오면 assertion
failure로 처리한다.

각 postprocess DSP는 tile 동안 하나의 output channel 계수를 고정하고 M32만 scan한다.
M selector는 M8 내부 8:1 register stage와 M-group 4:1 register stage로 나누며,
DSP48E2 A/D/B/M/P register와 후단 rounding/shift pipeline을 모두 사용한다. 결과도
독립 `ready/valid`를 가진 8개 N8 local scanner/FIFO/pool slice로 유지해 중앙
2,048-to-8 mux, global ready fanout과 64-wide global FIFO를 만들지 않는다. 한
slice가 stall되어도 다른 slice의 M scan은 진행한다. 이 변경은 DSP를 56개 더
쓰는 대신 200 MHz 배선 위험을 낮추며,
K26에는 160개 DSP가 routing/기타 기능 여유로 남는다.
각 slice의 output write는 8 INT8 = 64-bit/cycle이고 계수 8개는 tile 동안 local
register에 고정하므로 64 B/cycle burst를 단일 global memory port에 몰지 않는다.

## Output router 구조

Output router는 **8개**로 고정한다. 64-lane postprocess를 N8 단위로 정확히 나눠
`postprocess slice 0..7 -> router 0..7`로 1:1 연결한다. router 하나의 payload는
같은 M 좌표의 INT8 8개, 즉 64 bit/cycle이고, 전체 순간 burst는 512 bit/cycle이다.
중앙 512-bit crossbar/arbiter나 64개의 byte router는 두지 않는다.

각 router는 독립 `ready/valid`와 64-entry FIFO를 가진다. 한 entry는 N8 payload
8 B이므로 router당 payload 512 B, 8개 합계 4 KiB이며 M32 tile burst 두 개를
흡수한다. 한 router가 막혀도 나머지 7개는 계속 전송한다. FIFO가 full이어도 같은
cycle에 downstream pop이 있으면 새 packet을 받는다. descriptor의 destination과
N64 base는 FIFO가 완전히 빈 경계에서만 바꿔 서로 다른 tile tag가 섞이지 않게 한다.

| Producer layer | Router destination |
|---|---|
| Conv1, Conv2, Conv5 | local `3x3/s2` pool bank |
| Conv3, Conv4, FC6, FC7 | activation buffer / 다음 feeder |
| FC8 | final-output/logit buffer |

on-chip 물리 순서는 `[n64_tile][n8_slice][m][n_lane]`로 유지하고 NCHW 변환은 다음
feeder/packer가 담당한다. N tail은 inactive N8 slice의 `valid`를 내지 않고, 부분
slice가 생기면 `lane_mask` 밖 payload를 반드시 0으로 만든다. M tail은 packet의
좌표/valid로 제거한다. 현재 FC8 N=1000의 마지막 N64 tile은 base 960에서 slice
0..4만 활성이고 slice 5..7은 packet을 만들지 않는다.

이 수는 postprocess 개수와 함께 정한다. 현재 64 parallel output이므로 8개이고,
나중에 실제 timing 결과로 128 parallel output을 채택한다면 같은 64-bit granularity로
router도 16개가 필요하다. baseline은 DSP 1,088개를 쓰는 64 postprocess/8 router다.

## Buffer, DMA와 layer overlap

- 58.260 MiB weight 전체는 on-chip에 넣지 않는다.
- 165,504 B bias/multiplier/shift record 전체는 on-chip resident 후보로 둔다.
- weight는 full-K x N64, 최대 FC6 576 KiB tile을 URAM ping/pong한다.
- activation/line/patch buffer는 BRAM 중심으로 독립 banking한다.
- DDR layout은 `[layer][output_channel_tile][k][output_channel_lane]` K-major다.
- bank owner는 `EMPTY -> DMA_FILL -> READY -> COMPUTE -> EMPTY`로 고정한다.
- RS는 line/patch feeder에서 window overlap을 재사용하고, OS는 PE에서 psum을
  끝까지 보관하며, WS는 weight tile을 spatial position과 batch 사이에 유지한다.

200 MHz Conv1 예상 시간은 약 172.5 us다. Conv2 weight 307,200 B는 한 128-bit
port ideal 96 us이며, Conv1 종료 전 load에 필요한 유효 대역폭은 1.781 GB/s,
port efficiency 55.7%다. 따라서 long-burst 기준 overlap 가능한 목표지만, RTL에서
weight `READY`, Conv2 5-row prefill, descriptor/FIFO 상태를 함께 assertion한다.
FC6 전체 preload는 불가능하므로 576 KiB tile streaming과 weight-major batch 8/16
reuse가 필수다.

Dense analytical operand-read 기준 Hybrid는 Conv 합계 3.229 MiB/image로 pure
OS 30.846, pure WS 12.123, pure RS 21.953 MiB/image보다 각각 89.5%, 73.4%,
85.3% 적다. 전체 network batch 8은 8.174 MiB/image로 OS/WS/RS보다 각각
78.1%, 54.4%, 71.3% 적다. DMA overlap은 latency만 숨기며 byte 감소로 계산하지
않는다. 실제 RTL에서는 AXI byte counter로 이 식을 검증한다.

## Zero-skip 결정

| Conv | Input zero | Pair both-zero | M32 all-zero | 4x4 all-zero | Kernel-row | Full-window | Padding |
|---|---:|---:|---:|---:|---:|---:|---:|
| Conv1 | 0.61% | 0.03% | 0.00% | 0.00% | 0.00% | 0.00% | 0.99% |
| Conv2 | 28.76% | 21.96% | 2.66% | 9.09% | 0.00% | 0.00% | 8.69% |
| Conv3 | 52.66% | 43.23% | 6.81% | 16.03% | 0.00% | 0.00% | 9.99% |
| Conv4 | 84.59% | 78.61% | 21.47% | 48.11% | 0.00% | 0.00% | 9.99% |
| Conv5 | 82.37% | 75.96% | 19.23% | 44.03% | 0.00% | 0.00% | 9.99% |

첫 RTL에는 padding/tail structural skip과 packed-pair both-zero CE gating을 넣는다.
전자는 known-invalid lane의 read와 MAC switching을 줄이고, 발행 vector 전체가
invalid일 때만 cycle도 줄인다. 후자는 switching power만 줄인다. Kernel-row와
full-window는 0%라 LeNet row compaction을 제거한다. M32/4x4 compression은 late
layer 잠재 이득은 있지만 dense data를 읽은 뒤 검출하면 DDR byte가 줄지 않으므로
첫 RTL에는 counter만 넣고 compressed activation format phase로 분리한다. Exact-zero
weight는 1.19~3.88%뿐이므로 dense weight format을 유지한다.

## RTL testbench 진입 계약

| DUT | Golden/scoreboard | 필수 gate |
|---|---|---|
| packed PE | `packed_mac_ref` | signed lo/hi split, mask, INT32 extreme |
| local skew | `skew_ref` | tag alignment, stall hold, flush |
| RS feeder | `window_ref` | K11/5/3, stride/pad, row/tile tail |
| M32xN64 top | `sa_tile_ref` | fanout, M/N tail, result count/order |
| postprocess | `quant_ref` + `PostprocessScannerRef` | 8개 독립 N8/M32 scan, 32-cycle no-stall drain, N40 tail, slice별 stall hold, s27xs18 |
| output router | `N8OutputRouterRef` | 8개 N8 route, destination/N-base/tag, FIFO full, 동시 pop/push, 독립 stall, tail mask |
| pool | `maxpool_ref` | 3x3/s2, backpressure |
| DMA/layout | `layout_ref` | K-major N64, burst tail, ping/pong ownership |
| descriptor | `descriptor_ref` | K/M/N loop, address, timeout/error |
| full layer/network | `conv2d_ref`, `linear_ref`, `alexnet_ref` | every layer byte-exact |

Directed vector는 zero, `127`, `-128`, alternating sign, Conv1 corner/edge/center,
odd M/N tail, FC6 K=9216, positive/negative half-way rounding, saturation 경계,
random ready/valid stall, bank swap와 DMA error를 포함한다. 작은 DUT는 DPI로 비교하고
full layer는 `.bin + manifest + SHA-256`을 사용한다.

## 다음 단계

다음 커밋부터가 RTL 단계다. 우선순위는 packed PE와 local `M8xN8` skew,
RS feeder, result holding + N-stationary 64-lane postprocess, `M32xN64` registered top, DMA 순이다.
아직 닫히지 않은 항목은 합성 후 200 MHz timing/resource, 실제 AXI bandwidth,
KV260 board 전력/열, batch 8/16 throughput, 전체 ImageNet 50,000장 release 정확도다.
