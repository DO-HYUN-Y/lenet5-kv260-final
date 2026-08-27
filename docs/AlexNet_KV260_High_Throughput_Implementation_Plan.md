# AlexNet KV260 고처리량 가속기 구현 계획

- 최초 작성일: 2026-08-24
- 최근 설계 결정 반영일: 2026-08-27
- 대상 보드: AMD Kria KV260 / XCK26-SFVC784-2LV
- 기준 저장소: `DO-HYUN-Y/lenet5-kv260-final`
- 현재 상태: 계획 및 수치 검증 단계
- 설계 우선순위: 정확성 계약 고정 → 처리량 → TOPS/W → 단일 이미지 지연

## 0. 결정 요약

기존 LeNet-5 가속기는 유지하고, AlexNet은 별도의 고처리량 아키텍처로 구현한다. 기존 RTL의 검증된 signed INT8 DSP packing, AXI DMA 제어, Linux 런타임 경험은 재사용하되, 고정 LeNet controller와 작은 on-chip model/activation storage는 재사용하지 않는다.

새 가속기의 기본 데이터플로는 다음과 같다.

```text
DDR4 model/activation
  -> multi-port HP DMA
  -> URAM/BRAM double-buffered tiles
  -> row/window-stationary convolution feeder
  -> output-stationary packed-MAC PE array
  -> bias/requant/ReLU/pool
  -> DDR4 activation/output
```

핵심 결정은 다음과 같다.

1. RTL보다 먼저 Python FP32, Python INT8, C++ bit-exact 모델을 고정한다.
2. PE 내부 partial sum은 Output Stationary로 유지한다.
3. Conv 입력 row reuse는 line/window buffer 계층에서 확보한다.
4. weight는 DDR에 두고 tile 및 batch 단위로 재사용한다.
5. 단일 HP0 대신 여러 HP/HPC AXI 포트를 사용한다.
6. 처리량 측정은 batch 1과 batch 8 이상을 분리한다.
7. TOPS는 `1 MAC = 2 OPS`, 전력은 `VCC_SOM` 실측값으로 계산한다.
8. DSP 100% 점유가 아니라 250 MHz timing closure를 유지하는 최대 유효 점유를 목표로 한다.
9. 기본 SA는 logical `M8 x N8` tile을 계층적으로 결합한 `M32 x N64` 배열로 한다.
10. RS는 SA PE 안이 아니라 activation line/patch feeder에, WS는 URAM/BRAM weight tile 계층에, OS는 PE accumulator에 구현한다.
11. 기본 AlexNet 성능 수치에는 입력 sparsity 또는 zero skipping 이득을 포함하지 않는다.
12. DMA/compute overlap은 대기 시간을 숨기는 최적화이고, loop ordering과 on-chip residency는 실제 DDR byte를 줄이는 최적화로 구분한다.

## 1. RTL보다 먼저 고정할 실행 규격

### 1.1 Model contract

기준 모델은 `torchvision.models.alexnet`과 `AlexNet_Weights.IMAGENET1K_V1`으로 고정한다. 채널 수는 64/192/384/256/256이고 모든 convolution의 `groups=1`이다. 고전 Caffe의 96/256/384/384/256 grouped-convolution 모델과 혼용하지 않는다.

```text
alexnet/alexnet_contract.yaml
```

계약 파일에는 최소한 다음 항목이 들어가야 한다.

- 입력 크기: RGB `3x224x224`
- 입력 전처리: resize 256, center crop 224, ImageNet mean/std
- Conv1: kernel 11, stride 4, padding 2, output `64x55x55`
- 모든 convolution: `groups=1`
- LRN: 사용하지 않음
- Pool kernel, stride, padding
- classifier output class 수
- layer fusion 경계
- checkpoint SHA-256
- calibration dataset 버전과 seed
- 모델 및 vector format 버전

다음 항목이 확정되기 전에는 full RTL controller와 주소 맵을 고정하지 않는다.

고정한 layer shape와 INT8 weight 크기는 다음과 같다.

| Layer | Input | Kernel/stride/pad | Output | Dot-product K | INT8 weight |
|---|---|---|---|---:|---:|
| Conv1 | `3x224x224` | `11x11 / 4 / 2` | `64x55x55` | 363 | 23,232 B |
| Pool1 | `64x55x55` | `3x3 / 2 / 0` | `64x27x27` | - | - |
| Conv2 | `64x27x27` | `5x5 / 1 / 2` | `192x27x27` | 1,600 | 307,200 B |
| Pool2 | `192x27x27` | `3x3 / 2 / 0` | `192x13x13` | - | - |
| Conv3 | `192x13x13` | `3x3 / 1 / 1` | `384x13x13` | 1,728 | 663,552 B |
| Conv4 | `384x13x13` | `3x3 / 1 / 1` | `256x13x13` | 3,456 | 884,736 B |
| Conv5 | `256x13x13` | `3x3 / 1 / 1` | `256x13x13` | 2,304 | 589,824 B |
| Pool5 | `256x13x13` | `3x3 / 2 / 0` | `256x6x6` | - | - |
| FC6 | 9,216 | - | 4,096 | 9,216 | 37,748,736 B |
| FC7 | 4,096 | - | 4,096 | 4,096 | 16,777,216 B |
| FC8 | 4,096 | - | 1,000 | 4,096 | 4,096,000 B |

전체 weight는 `61,090,496 B = 58.260 MiB`이다. FC6~FC8은
`58,621,952 B = 55.906 MiB`, 즉 전체의 약 95.96%이므로 AlexNet의
DDR traffic과 batch 정책은 FC weight가 지배한다.

### 1.2 Numeric contract

초기 기준 정밀도는 다음과 같다.

| 항목 | 기준 |
|---|---|
| Activation | signed INT8 |
| Weight | signed INT8 |
| Zero point | 0, symmetric |
| Product | exact signed INT8 × INT8 |
| Accumulator | signed INT32 |
| Bias | signed INT32 |
| Scale | layer 또는 output-channel별 fixed-point |
| Output | signed INT8 saturation `[-128, 127]` |

반드시 코드로 하나만 고정할 세부 규칙은 다음과 같다.

- bias 적용 시점
- ReLU 적용 시점
- requantization multiplier 폭
- right-shift 및 rounding 규칙
- 음수 rounding 규칙
- saturation 순서
- padding 값
- dense convolution의 input/output channel 순서

비대칭 UINT8 activation을 채택하려면 기존 INT8 packing을 그대로 사용하지 않고 zero-point 보상식 또는 WP487 UINT8 방식을 별도로 검증한다.

### 1.3 Tensor ABI

다음 layout은 Python, C++, packer, RTL, driver가 공유하는 단일 ABI로 정의한다.

- activation layout: NCHW 또는 tiled-NCHW
- weight layout: OIHW
- output-channel tile order
- spatial tile order
- packed DSP lo/hi lane order
- DDR byte order와 alignment
- scale/bias record layout
- descriptor version과 checksum

## 2. Golden model 체계

### 2.1 Python FP32 reference

역할:

- checkpoint 정확도 확인
- preprocessing 기준 고정
- layer shape와 operator 의미론 확인
- FP32 per-layer output 저장

통과 조건:

- 선택한 validation set에서 baseline 정확도 재현
- 모든 layer shape가 contract와 일치
- checkpoint 및 preprocessing hash 기록

### 2.2 Python INT8 integer reference

fake quantization 결과만 사용하지 않고 실제 integer convolution과 requantization 경로를 구현한다.

역할:

- quantization 정확도 측정
- per-layer INT32 accumulator 범위 측정
- bias/scale/rounding/saturation 기준 고정
- per-layer INT8 golden tensor 생성

통과 조건:

- 목표 정확도 하락 범위 충족
- overflow가 없는 accumulator 및 postprocess 폭 증명
- 동일 입력에서 반복 실행 결과 완전 일치

### 2.3 C++ bit-exact reference

C++ 모델은 RTL의 직접적인 functional oracle이다. cycle timing을 모사하지 않고 정수 연산 결과와 메모리 layout을 모사한다.

필수 operator:

- packed INT8 product split
- dense Conv2D
- MaxPool
- ReLU
- FC/GEMM
- bias/ReLU/requantization
- tensor pack/unpack
- descriptor parser

통과 조건:

```text
Python INT8 tensor == C++ tensor
```

모든 layer에서 byte-exact가 되어야 하며, final logit만 비교하는 방식으로 대체하지 않는다.

Golden 코드는 testbench마다 계산식을 복사하지 않고 다음 공통 C++ library로 구성한다.

| C++ module | 책임 |
|---|---|
| `quant_ref` | bias, multiplier, shift, rounding, ReLU, saturation |
| `packed_mac_ref` | signed INT8 packed lo/hi product split과 INT32 누적 |
| `window_ref` | stride/padding/tile/lane mask를 포함한 logical window 생성 |
| `conv2d_ref` | dense Conv2D integer 결과 |
| `maxpool_ref` | AlexNet `3x3`, stride 2 max pooling |
| `linear_ref` | FC/GEMM integer 결과 |
| `layout_ref` | NCHW/tiled activation 및 K-major weight pack/unpack |
| `descriptor_ref` | descriptor decode, loop bounds, DDR address 계산 |
| `alexnet_ref` | operator들을 결합한 full-network byte-exact 결과 |

SystemVerilog DPI 함수는 이 공통 library를 호출하는 얇은 wrapper로만 만든다.
Golden model은 숫자와 transaction 순서를 정의하고 cycle-accurate timing은 모사하지
않는다. `valid/ready`, stall, latency, flush 및 tag 정렬은 SV testbench의 queue
scoreboard가 검증한다. Logical tensor reference와 실제 DDR/SA packing reference도
분리하여, 산술 오류와 layout 오류를 독립적으로 찾을 수 있게 한다.

## 3. DSP packing 및 accumulator 규격

### 3.1 기존 packing의 적용 범위

현재 `packed_pe`는 한 DSP48E2에서 다음 계산을 수행한다.

```text
AD = (packed_hi << 18) + packed_lo
P  = AD * common_operand

prod_lo = signed(P[17:0])
prod_hi = signed(P[35:18]) + P[17]
```

현재 구현은 packed 상태를 363회 누적하지 않는다. 매 cycle 두 product를 분리한 뒤 독립적인 INT32 accumulator에 누적한다. 따라서 dot-product depth 자체에는 7항 제한이 없다.

Conv1의 최악 조건은 다음과 같다.

```text
depth = 11 * 11 * 3 = 363
max   = 363 * 16384  =  5,947,392
min   = 363 * -16256 = -5,900,928
```

signed 24-bit로 표현 가능하므로 INT32 accumulator는 안전하다.

### 3.2 금지하는 구현

18-bit 간격의 packed word를 분리하지 않고 DSP48E2 P accumulator에 363회 연속 누적하지 않는다. WP487 방식에서 해당 packed dot-product의 직접 누적은 INT8×INT8 기준 최대 7항까지만 안전하다.

### 3.3 구현 후보

#### 후보 A: split-every-cycle OS

- 기존 방식과 동일
- 2 MAC/DSP
- 두 개의 독립 INT32 fabric accumulator
- 가장 단순한 bit-exact bring-up 경로
- 대규모 배열에서는 LUT/FF/routing/power 부담이 큼

#### 후보 B: 7-term packed cascade

- 최대 7항을 DSP 내부에서 packed 누적
- chunk 종료 시 18-bit field를 분리하고 24/32-bit partial sum으로 확장
- 긴 K는 partial sum 계층에서 누적
- 추가 DSP adder를 사용하면 이론상 약 1.75 MAC/DSP
- raw DSP 밀도는 낮지만 Fmax와 TOPS/W가 더 높을 가능성이 있음

두 후보는 동일 test vector와 동일 target frequency에서 합성 및 power estimate를 비교한다. 최종 선택은 peak MAC/DSP가 아니라 achieved TOPS/W와 timing margin으로 결정한다.

### 3.4 AlexNet accumulator 최소 폭

signed INT8의 전체 범위를 사용하는 최악 조건 기준이다.

| Layer | Dot-product depth | 최소 signed 폭 |
|---|---:|---:|
| Conv1 | 363 | 24-bit |
| Conv2 | 1,600 | 26-bit |
| Conv3 | 1,728 | 26-bit |
| Conv4 | 3,456 | 27-bit |
| Conv5 | 2,304 | 27-bit |
| FC6 | 9,216 | 29-bit |
| FC7/FC8 | 4,096 | 28-bit |

INT32 accumulator는 전체 layer에 충분하다. 기존 `dual_lane_postprocess`의 27-bit multiplier input clamp는 AlexNet 최악 조건을 보장하지 못하므로 그대로 재사용하지 않는다. calibration으로 실제 범위를 제한하거나 postprocess 입력 폭과 scaling 구조를 다시 설계한다.

## 4. 목표 microarchitecture

### 4.1 계층형 hybrid dataflow

순수 Row Stationary 또는 순수 Output Stationary 대신 메모리 계층별 역할을 분리한다.

| 계층 | Stationary 대상 | 목적 |
|---|---|---|
| DDR/URAM | weight tile | batch 및 spatial reuse |
| BRAM/line buffer | activation row/window | overlapping-window reuse |
| PE | output partial sum | INT32 psum 이동 제거 |

Conv1 기준 reuse는 다음과 같다.

- weight: output spatial 위치 3,025개에서 재사용
- input: stride 4를 고려해 평균 약 7개 window에서 재사용
- partial sum: PE 내부에서 363항 누적

### 4.2 Base SA tile과 전체 배열

기본 compute tile은 기존 packed PE를 재사용한 logical `M8 x N8`이다.

```text
physical PE array = 4 packed-spatial rows x 8 output-channel columns
logical MAC array = 8 spatial lanes x 8 output channels
DSP per base tile = 4 x 8 = 32
MAC per cycle     = 8 x 8 = 64
```

전체 목표 배열은 base tile 32개를 `4 M-groups x 8 N-groups`로 결합한다.

```text
logical M = 4 x 8 = 32 spatial/batch lanes
logical N = 8 x 8 = 64 output channels
packed MAC DSP = 32 base tiles x 32 DSP = 1,024 DSP
MAC per cycle = 2,048
postprocess DSP = 32 to 64
total DSP target = 1,056 to 1,088 / 1,248
```

Conv는 `A[P,K] x B[K,Cout]`에서 M을 spatial position, N을 output
channel로 사용한다. FC도 같은 operand 방향을 유지하되 M을 batch image로 사용한다.
첫 AlexNet 구현에서는 기존 LeNet FC의 operand-role swap mode를 제거한다. 이 mode를
대규모 배열에 확장하면 FC weight 공급 폭과 별도 제어가 급증하기 때문이다. 그 결과
FC batch 1에서는 M lane utilization이 낮지만, 기능 경로가 단순하고 batch 8/16/32에서
자연스럽게 weight broadcast와 M-lane utilization을 높일 수 있다.

### 4.3 Skew와 global broadcast 구조

`M32 x N64` 전체에 하나의 거대한 skew chain을 만들지 않는다. 각 logical
`M8 x N8` base tile 안에서만 기존과 같은 local skew를 사용한다.

```text
activation pair group g delay = g cycles
weight column c delay         = c cycles
alignment cycle               = issue + k + g + c
```

상위 계층에서는 같은 activation stream을 8개 N-group으로 registered tree를 통해
공유하고, 같은 weight stream을 4개 M-group으로 공유한다. 긴 combinational fanout,
global clock enable, global skew를 금지하고 partition별 pipeline register와 local CE를
둔다. timing이 실패하면 2개 또는 4개의 독립 partition으로 나누고 각 partition에
로컬 buffer/controller를 둔다.

SA token/control interface에는 최소한 다음 필드를 둔다.

- `step_valid`: 이 cycle의 K token 유효 여부
- `acc_clear`: 새 output tile accumulator 초기화
- `chunk_last`: packed/cascade 내부 chunk 종료
- `reduce_last`: 전체 dot product K 종료 및 결과 방출
- `lane_mask`: spatial/batch tail 및 padding lane 무효화
- `k_tag`, `tile_tag`: activation/weight/psum 정렬 검증
- `flush`: pipeline drain

`reduce_last`에서만 최종 output을 방출하고 accumulator를 새 dot product로 넘긴다.
simulation assertion으로 activation과 weight의 `k_tag`가 일치하는지, stall 시 data와
모든 tag가 함께 hold되는지 검증한다.

### 4.4 AlexNet RS feeder

기존 LeNet `window_gen_runtime`은 최대 kernel 5, stride 1 중심의 7-row FF
buffer이므로 AlexNet Conv1에 그대로 재사용하지 않는다. 새 feeder는 kernel
11/5/3, stride 4/1, padding 2/1/0과 row boundary를 runtime descriptor로 처리한다.

logical M8 group에 필요한 입력 patch 폭은 다음과 같다.

```text
patch_width = (M - 1) * stride + kernel_width
Conv1 M8    = (8 - 1) * 4 + 11 = 39 pixels
```

따라서 Conv1은 8개 output 위치에 단순히 18 pixel을 읽는 stride-1 window가 아니라
39 pixel 범위에서 `ix=(ox_base+m)*stride+kx-pad`로 선택해야 한다. M32는 네 개의
M8 feeder/group으로 구성하고 banked patch buffer와 registered selector를 사용한다.
padding과 row/tile tail은 실제 memory read 대신 mask로 생성한다.

현재 LeNet의 `2x2` pool도 재사용하지 않고 AlexNet용 `3x3`, stride 2 max-pool을
작성한다. Conv/ReLU/Pool 사이에는 FIFO를 두어 가능한 row부터 다음 layer feeder로
전달할 수 있게 한다.

### 4.5 Resource budget

자원 100% 점유는 목표가 아니다. timing closure와 board power를 포함한 유효 성능을 목표로 한다.

| Resource | 목표 상한 |
|---|---:|
| DSP48E2 | 1,088 / 1,248, 약 87% |
| LUT | 90,000 / 117,120, 약 77% |
| FF | 180,000 / 234,240, 약 77% |
| BRAM | 125 / 144, 약 87% |
| URAM | 56 / 64, 약 88% |

상한을 넘으면 배열 크기보다 Fmax, clock enable, data fanout, memory banking을 먼저 재검토한다.

## 5. Memory 및 DMA 계획

### 5.1 DDR roofline

K26 DDR4는 64-bit, 2400 Mb/s이므로 device raw bandwidth는 19.2 GB/s이다.
AlexNet INT8 weight `61,090,496 B`를 이미지마다 읽으면 batch 1은 FC weight
bandwidth에 의해 memory-bound가 된다. PL-side 128-bit AXI port의 이론값은 다음과
같다.

```text
150 MHz: 2.4 GB/s per port
200 MHz: 3.2 GB/s per port
250 MHz: 4.0 GB/s per port
```

이는 protocol overhead가 없는 상한이다. burst length, outstanding transaction,
DDR controller arbitration과 실제 efficiency를 board에서 측정한다. 새 설계는 단일
HP0에 의존하지 않고 여러 128-bit HP/HPC port를 사용한다.

권장 분할:

- HP0/HP1: weight read
- HP2: activation read
- HP3: activation/result write
- AXI-Lite/HPM: control only

### 5.2 Batch reuse

FC weight가 전체 weight traffic을 지배하므로 weight tile을 한 번 읽은 뒤 여러 이미지에 적용한다.

| Mode | 목적 |
|---|---|
| Batch 1 | latency 및 기능 검증 |
| Batch 4 | DDR/compute balance 확인 |
| Batch 8 | 기본 throughput 측정 |
| Batch 16 | bandwidth headroom 및 TOPS/W 측정 |

batch는 MAC 수를 줄이는 기능이 아니다. 동일 weight tile이 URAM에 있는 동안 여러
입력 이미지에 적용하여 weight의 DDR read를 이미지 사이에서 재사용하는 실행
schedule이다. 이미지 우선 loop에서는 batch를 사용해도 weight가 반복 로드된다.

```text
금지하는 image-major schedule:
for b
  for layer
    for oc_tile
      dma_load(weight_tile)       // 같은 weight를 B번 로드
      compute_all_spatial_tiles

기본 layer/weight-major schedule:
for layer
  for oc_tile
    dma_load(weight_tile)         // batch 전체에서 한 번 로드
    for batch_tile
      for spatial_tile
        compute
```

예를 들어 FC6 weight는 `36 MiB`이다. batch 8 image-major는 총 `288 MiB`,
이미지당 `36 MiB`를 읽지만 weight-major는 총 `36 MiB`, 이미지당 `4.5 MiB`를
읽는다. loop가 데이터를 없애는 것이 아니라 loop ordering이 weight의 on-chip
residency 기간을 결정하며, 실제 URAM/BRAM 공간과 함께 사용될 때만 DDR byte가
감소한다.

batch tensor 전체를 반드시 한 번에 on-chip에 보관하지는 않는다. weight tile은
유지하고 activation은 이미지별 또는 batch tile별로 순환한다. FC6 input은 이미지당
9,216 B이므로 batch 8이면 72 KiB이며 온칩 저장이 가능하다. Conv activation은
크기와 port pressure에 따라 온칩 유지 또는 DDR 재독을 layer별로 결정한다.

Batch 1, 4, 8, 16은 서로 다른 성능 mode로 모두 보고한다. 한 카메라에서 B개
frame을 모으면 queueing latency가 증가하므로 batch throughput을 batch-1 latency로
표현하지 않는다.

### 5.3 On-chip buffer

다음 buffer를 독립 banking한다.

- weight tile ping/pong
- activation tile ping/pong
- convolution line/window buffer
- INT32 partial-sum buffer
- bias/scale buffer
- descriptor queue

DMA와 compute를 겹치기 위해 각 ping/pong buffer는 명시적인 owner와 completion handshake를 가진다.

전체 weight 58.260 MiB는 온칩에 들어가지 않지만 bias/scale/shift 등 parameter는
resident로 둘 수 있다. 전체 output-channel record 수는 10,344이고 16 B record를
사용해도 165,504 B이다.

주요 INT8 activation 크기는 input 150,528 B, Conv1 output 193,600 B, Pool1
output 46,656 B, Conv2 output 139,968 B, Pool2 output 32,448 B, Conv3 output
64,896 B, Conv4/5 output 43,264 B, Pool5 output 9,216 B이다. 최대 activation 두
개를 단순 ping/pong으로 잡으면 약 387,200 B가 필요하므로 K26의 약 648 KiB BRAM에
parameter, line buffer, FIFO까지 모두 무계획하게 배치하지 않는다. weight는 URAM,
activation/line buffer는 BRAM 중심으로 두되 남는 URAM과 distributed RAM을 포함한
구체적 배치는 synthesis 결과로 조정한다.

weight buffer는 full-K x N64 supertile을 기본 단위로 한다.

| Layer | K x N64 tile | N64 tile 수 |
|---|---:|---:|
| Conv1 | 23,232 B | 1 |
| Conv2 | 102,400 B | 3 |
| Conv3 | 110,592 B | 6 |
| Conv4 | 221,184 B | 4 |
| Conv5 | 147,456 B | 4 |
| FC6 | 589,824 B = 576 KiB | 64 |
| FC7 | 262,144 B | 64 |
| FC8 | 262,144 B | 16, 마지막 tile은 N=40 |

가장 큰 FC6 tile은 logical `512-bit x 9,216`이다. URAM을 `72-bit x 4,096`
primitive로 banking하면 width 방향 8개, depth 방향 3개, 즉 bank당 약 24 URAM이
필요하고 ping/pong은 약 48 URAM을 사용한다. 구현 시 padding된 physical layout과
실제 utilization을 synthesis report로 확인한다.

DDR weight blob은 SA가 한 cycle에 요구하는 64개 output-channel weight를 burst로
받을 수 있도록 다음 K-major layout을 사용한다.

```text
[layer][output_channel_tile][k][output_channel_lane]
```

각 weight bank의 상태 전이는 다음으로 고정한다.

```text
EMPTY -> DMA_FILL -> READY -> COMPUTE -> EMPTY
```

DMA는 inactive bank에만 쓰고 SA는 active bank만 읽는다. `current_compute_done &&
next_bank_ready && !dma_error`일 때만 bank를 교환하며 dot product 중간에는 절대
교환하지 않는다.

### 5.4 Activation residency와 loop blocking

Conv에서 weight tile을 outer loop에 놓으면 weight는 한 번만 읽지만, 전체 input
feature map이 온칩에 없을 경우 output-channel tile마다 activation을 다시 읽는다.
반대로 activation을 outer에 두면 activation은 한 번 읽지만 모든 weight가 온칩에
없을 경우 weight tile을 반복 로드한다. 따라서 loop 순서만으로 두 operand를 모두
한 번씩 읽을 수는 없고 buffer capacity가 함께 필요하다.

현재 hybrid의 보수적 기준은 다음이다.

- RS feeder가 im2col 중복을 제거한다.
- full-K x N64 weight tile은 모든 spatial position에서 재사용한다.
- activation 전체를 output-channel tile 사이에서 유지하지 못하면 N64 tile 수만큼 재독한다.
- activation 전체 또는 충분한 stripe가 buffer에 들어가면 layer별로 `I+W`에 접근한다.

예를 들어 Conv2는 input 46,656 B, 전체 weight 307,200 B, N64 tile 3개이다.

```text
activation을 N64 tile마다 재독: 46,656*3 + 307,200 = 447,168 B = 0.426 MiB
activation 전체를 유지:       46,656   + 307,200 = 353,856 B = 0.337 MiB
```

DMA double buffering, AXI burst 폭 증가, outstanding transaction 증가는 같은 byte를
더 빨리 전달하여 stall을 줄이지만 byte 수를 줄이지 않는다. RS, WS residency,
batch reuse, layer fusion 및 압축만 실제 DDR byte를 줄이는 항목으로 보고한다.

### 5.5 Conv1 계산과 Conv2 weight load overlap

`M32 x N64`, 200 MHz에서 Conv1은 spatial tile `ceil(3025/32)=95`, K=363이다.

```text
core cycles = 95 * 363 = 34,485 cycles
local drain 포함 예상 = 약 34,499 cycles = 172.5 us
```

Conv2 전체 weight는 307,200 B이며 inactive 576 KiB weight bank 하나에 들어간다.

```text
128-bit x 200 MHz 한 port ideal load = 96 us
두 port stripe ideal load           = 48 us
Conv1 종료 전 완료에 필요한 한 port effective bandwidth = 1.781 GB/s
필요 efficiency = 55.7%
```

따라서 정상적인 long-burst에서 Conv2 weight DMA는 Conv1 종료 전에 완료 가능한
설계 목표다. 실제로 Conv2를 bubble 없이 시작하려면 weight뿐 아니라 다음 조건을
모두 만족해야 한다.

- Conv2 weight bank `READY`
- Conv2 feeder의 5개 row slot 준비(첫 output row는 상단 padding 2개와 실제 Pool1 row 3개)
- bias/scale descriptor 준비
- result/postprocess/pool FIFO가 full이 아님
- DMA error와 tag mismatch가 없음

Conv1의 평균 result 발생률은 `2048/363 = 5.64 output/cycle`이므로 result capture
FIFO와 requant/ReLU/pool intake는 최소 8 lane/cycle을 목표로 한다. Conv1 결과가
나오는 즉시 ReLU와 Pool1을 거쳐 Conv2 feeder를 prefill한다. layer 경계에서 SA
전체 reset을 사용하지 않고 `reduce_last`와 다음 `acc_clear` token으로 전환한다.

Conv5 계산 중 FC6 전체 36 MiB를 미리 가져오는 것은 불가능하다. FC6은 576 KiB
tile 단위 ping/pong streaming과 batch reuse가 필수다. 200 MHz에서 FC6 tile load는
한 128-bit port ideal 184.3 us, 두 port ideal 92.2 us이고 한 batch-tile compute는
최소 9,216 cycle=46.1 us이므로 FC 구간은 실측 DDR bandwidth와 batch wave 수에
따라 memory-bound가 될 수 있다.

### 5.6 OS/RS/WS baseline과 DDR 접근량 비교

비교가 구현 정의에 따라 달라지지 않도록 다음 dense analytical baseline을 고정한다.
INT8 operand read만 계산하고 output write, descriptor/parameter read는 모든 설계에
공통이므로 제외한다. 또한 baseline에 유리하도록 external partial-sum spill은 없다고
가정한다. line buffer나 cross-tile cache를 추가한 pure baseline은 해당 기능이 이미
RS/WS hybrid이므로 별도 결과로 표시한다.

Conv layer에서 다음 기호를 사용한다.

```text
P  = Hout * Wout
K  = Cin * Kh * Kw
Nt = ceil(Cout / 64)
Mt = ceil(P / 32)
I  = Cin * Hin * Win
W  = K * Cout
Acol = P * K
```

Batch 1 operand read 식은 다음과 같다.

```text
Pure OS     = Acol*Nt + W*Mt    // psum만 stationary
Pure WS     = Acol*Nt + W       // weight는 layer spatial 전체에서 재사용
Pure RS     = I*Nt    + W*Mt    // raw input row/window만 재사용
Hybrid      = I*Nt    + W       // RS + WS + OS, activation은 N tile마다 재독
Hybrid ideal= I       + W       // activation도 N tile 사이에서 온칩 유지
```

| Layer | Pure OS | Pure WS | Pure RS | Hybrid | Hybrid ideal |
|---|---:|---:|---:|---:|---:|
| Conv1 | 3.152 MiB | 1.069 MiB | 2.248 MiB | 0.166 MiB | 0.166 MiB |
| Conv2 | 10.075 MiB | 3.630 MiB | 6.872 MiB | 0.426 MiB | 0.337 MiB |
| Conv3 | 5.468 MiB | 2.304 MiB | 3.983 MiB | 0.818 MiB | 0.664 MiB |
| Conv4 | 7.291 MiB | 3.072 MiB | 5.310 MiB | 1.091 MiB | 0.906 MiB |
| Conv5 | 4.860 MiB | 2.048 MiB | 3.540 MiB | 0.728 MiB | 0.604 MiB |
| **Conv 합계** | **30.846 MiB** | **12.123 MiB** | **21.953 MiB** | **3.229 MiB** | **2.676 MiB** |

현재 Hybrid의 Conv operand read는 pure OS 대비 9.55배/89.5%, pure WS 대비
3.75배/73.4%, pure RS 대비 6.80배/85.3% 감소한다. activation까지 N tile 사이에서
유지하면 각각 11.53배/91.3%, 4.53배/77.9%, 8.20배/87.8% 감소한다.

AlexNet 전체에서는 FC compulsory weight read가 지배하므로 batch 조건을 함께
표시한다. 아래 batch 수치는 FC에서 M=batch로 mapping하고, WS/Hybrid는 Conv
weight도 batch 사이에서 유지한다. Pure OS/RS Conv는 각 dataflow 정의대로 spatial
tile weight 재독을 유지한다.

| Mode | Batch 1 | Batch 8 | Batch 16 |
|---|---:|---:|---:|
| Pure OS | 87.627 MiB/image | 37.390 MiB/image | 33.749 MiB/image |
| Pure WS | 68.904 MiB/image | 17.926 MiB/image | 14.285 MiB/image |
| Pure RS | 78.734 MiB/image | 28.497 MiB/image | 24.855 MiB/image |
| Hybrid | 59.152 MiB/image | 8.174 MiB/image | 4.533 MiB/image |
| Hybrid ideal | 58.599 MiB/image | 7.621 MiB/image | 3.980 MiB/image |

Hybrid의 전체-network 감소율은 batch 1에서 OS/WS/RS 대비 각각
32.5%/14.2%/24.9%, batch 8에서 78.1%/54.4%/71.3%, batch 16에서
86.6%/68.3%/81.8%이다. Batch 1에서 pure WS 대비 차이가 작은 이유는 모든
설계가 FC weight 55.906 MiB를 적어도 한 번 읽기 때문이다. 이 표는 RTL 구현 후
AXI performance counter의 실제 read byte와 다시 비교한다.

reuse를 MAC per DDR-read element 관점으로도 보고한다.

| Reuse 종류 | Conv1 | Conv2 | Conv3 | Conv4 | Conv5 |
|---|---:|---:|---:|---:|---:|
| Weight reuse/image (`P`) | 3,025 | 729 | 169 | 169 | 169 |
| RS spatial reuse (`Acol/I`) | 7.29 | 25 | 9 | 9 | 9 |
| Hybrid activation reuse/read (`RS*N64`) | 약 467 | 1,600 | 576 | 576 | 576 |
| Ideal activation reuse/read (`RS*Cout`) | 약 467 | 4,800 | 3,456 | 2,304 | 2,304 |
| OS psum local accumulation (`K`) | 363 | 1,600 | 1,728 | 3,456 | 2,304 |

weight reuse는 batch B에서 `P*B`로 증가한다. 예를 들어 Conv2는 batch 8에서
weight 한 byte당 5,832 MAC에 사용된다. SA 내부 한 cycle에는 activation 32 B와
weight 64 B를 공급해 2,048 MAC을 만들므로 local activation read 하나는 64 MAC,
local weight read 하나는 32 MAC에서 재사용되고 psum은 최종 결과 전까지 PE 밖으로
쓰지 않는다.

## 6. 성능 및 전력 목표

### 6.1 산정 기준

torchvision AlexNet FP32 모델에서 검증한 sizing 기준:

```text
714,188,480 MAC/image
1,428,376,960 OPS/image
```

TOPS 계산:

```text
TOPS = MAC/image * 2 * image/s / 1e12
TOPS/W = TOPS / measured_VCC_SOM_W
```

### 6.2 Target

| 항목 | 최소 목표 | 목표 | Stretch |
|---|---:|---:|---:|
| PL clock | 200 MHz | 250 MHz | 300 MHz |
| Batch throughput | 350 image/s | 450-565 image/s | 600+ image/s |
| Achieved performance | 0.50 TOPS | 0.65-0.82 TOPS | 0.90+ TOPS |
| SOM application power | - | <= 10 W | <= 11.5 W |
| Achieved TOPS/W | 0.05 | 0.07-0.09 | 0.10+ |
| Batch-1 throughput | 100 image/s | 150-220 image/s | 230+ image/s |

1,024 packed-MAC DSP의 peak는 다음과 같다.

```text
200 MHz: 0.819 TOPS, peak 573.5 image/s
250 MHz: 1.024 TOPS, peak 716.9 image/s
300 MHz: 1.229 TOPS, peak 860.3 image/s
```

이 수치는 목표 설정용 roofline이며 구현 완료를 의미하지 않는다.

### 6.3 Power measurement

Vivado vectorless power estimate만으로 최종 TOPS/W를 보고하지 않는다.

필수 측정:

- idle `VCC_SOM` power
- batch 1 steady-state power
- batch 8/16 steady-state power
- clock별 200/225/250/275/300 MHz sweep
- device temperature
- throttle 또는 error 여부
- 60초 이상 sustained throughput

보고값:

```text
SOM_W_avg
SOM_W_peak
image/s
image/J
achieved_TOPS
achieved_TOPS/W
```

### 6.4 AlexNet zero skipping 결정

LeNet의 row-zero compaction을 AlexNet 처리량 목표에 그대로 포함하지 않는다. 기존
구조는 line-buffer row 전체가 0이면 해당 kernel row의 `kernel_col*channel` token을
제거한다. MNIST에는 검은 배경의 all-zero row가 많지만 자연 RGB image는
normalization 이후 정확한 zero row가 거의 없다. ReLU 이후 element zero는 많을 수
있어도 여러 channel과 width 전체가 동시에 0인 structured row는 별개다.

예를 들어 Conv2 input row에는 `27*64=1,728` element가 있다. 독립적인 element
zero rate를 70%로 가정해도 full-row zero 확률은 `0.7^1728`, 사실상 0이다. 또한
M32 SA에서 K cycle을 통째로 제거하려면 같은 K의 32개 activation이 모두 0이어야
한다. 일부 lane만 0이면 나머지 lane 때문에 global K cycle은 진행해야 한다.

zero 최적화는 다음 세 등급으로 분리한다.

1. **Structural skip:** padding, spatial/channel tail과 명시적 mask는 읽기 전에 알 수
   있으므로 `lane_mask/k_mask`로 memory read와 MAC token을 생략한다.
2. **Zero-value gating:** packed activation 두 lane이 모두 0이면 해당 PE/M-group의
   CE를 내려 switching을 줄인다. cycle 수와 DDR byte는 줄지 않으므로 power
   최적화로만 보고한다.
3. **Sparse compression/compaction:** bitmap 또는 block metadata로 zero block을 DDR에
   저장하지 않고 K token까지 압축한다. DDR byte와 cycle을 모두 줄일 수 있지만
   index matching, decompressor, random weight access와 lane load balancing이 필요하므로
   dense baseline 이후 별도 phase로 둔다.

row를 load한 뒤 zero를 검출하는 기존 방식은 이미 activation을 읽었으므로 activation
DDR byte를 줄이지 않는다. weight tile도 DMA 완료 후 zero를 발견하면 DDR weight
byte는 그대로이고 URAM read/MAC만 줄어든다. DDR byte 감소를 주장하려면 padding처럼
읽기 전에 zero임을 알거나 sparse bitmap/compressed format을 사용해야 한다.

signed symmetric INT8에서는 numeric zero의 code가 0이다. 향후 asymmetric UINT8을
채택하면 `activation == zero_point`를 검사하고 MAC에도 zero-point 보상을 적용해야
하므로 현재 `(pix != 0)` 검출을 재사용하지 않는다.

첫 dense RTL에는 다음 counter를 넣어 실제 calibration/validation image에서
granularity별 sparsity를 측정한다.

- `element_zero_count`
- `packed_pair_both_zero_count`
- `m32_vector_all_zero_count`
- `full_row_zero_count`
- `block_4x4_zero_count` 또는 선택한 block 크기
- `padding_skipped_token_count`
- `total_activation_count`, `skipped_cycle_count`

기본 구현은 structural skip만 성능 기능으로 사용한다. packed-pair zero가 충분하면
CE gating을 추가하고, block/vector zero가 구현 비용을 상쇄할 만큼 측정된 경우에만
block-sparse engine 또는 structured pruning을 검토한다. 모든 OS/RS/WS baseline
memory-access 표는 sparsity 이득을 제외한 dense worst-case 수치로 유지한다.

## 7. 구현 단계 및 통과 게이트

### Phase 0 — Contract freeze

산출물:

- `alexnet_contract.yaml`
- checkpoint 및 calibration hash
- tensor/descriptor ABI 문서
- 성능 측정 정의

Gate:

- 팀과 멘토가 model/numeric contract 승인
- 변경 시 version bump 규칙 확정

### Phase 1 — Python references

현재 진행 상태:

- 완료: torchvision 호환 FP32 모델, 224 입력 전처리 계약, 공식 V1 checkpoint SHA-256, layer shape/MAC smoke test
- 대기: ILSVRC2012 validation 50,000장 Top-1/Top-5 실측
- 다음: 실제 integer INT8 reference 및 per-layer golden tensor

산출물:

- FP32 inference
- integer INT8 inference
- per-layer tensor dump
- accumulator range report

Gate:

- baseline 정확도 재현
- INT8 정확도 목표 충족
- 동일 입력 반복 결과 deterministic

### Phase 2 — C++ bit-exact golden

현재 상태 (2026-08-27):

- `alexnet/cpp` 공통 library에 quant, packed PE, packed SA tile, window/RS,
  dense/grouped Conv2D, MaxPool, FC, layout, DMA burst/ping-pong ownership,
  descriptor/DDR address, skew timing, full-network 모델을 구현했다.
- 얇은 C ABI/DPI wrapper와 CMake/CTest 회귀 테스트를 추가했으며 20,812개
  directed/random check가 통과한다.
- 실제 calibration multiplier/shift와 Python INT8 per-layer tensor exporter는 아직
  미정이므로 `Python INT8 == C++` layer별 byte-exact gate는 Phase 1 완료 후 닫는다.

산출물:

- dense Conv/Pool/FC/requant C++ model
- pack/unpack model
- directed/random test-vector generator

Gate:

- Python INT8와 모든 layer byte-exact
- extreme-value 및 padding test 통과

### Phase 3 — Packed-MAC exploration

산출물:

- split-every-cycle OS PE
- 7-term packed cascade PE
- 동일 clock/resource/power 비교 보고서

Gate:

- C++ golden과 bit-exact
- post-route 250 MHz 후보 최소 1개
- DSP packing corner case 전수 또는 충분한 formal/random 검증

### Phase 4 — Conv/FC tile engine

산출물:

- runtime K/M/N descriptor
- K11/K5/K3, stride/padding-aware M8 line/patch feeder
- physical `4x8` / logical `M8xN8` local-skew OS base tile
- registered broadcast tree로 결합한 `M32xN64` top array
- INT32 partial-sum 처리
- 8-lane 이상 postprocess와 AlexNet `3x3/s2` pooling
- token/tag assertion과 sparsity performance counter

Gate:

- Conv1 전체 output byte-exact
- Conv2 output byte-exact
- FC6 worst-depth test 통과
- backpressure/stall 주입 test 통과
- local skew `k_tag/tile_tag` alignment assertion 통과
- 200 MHz post-route 최소 통과 후 250 MHz closure 시도

### Phase 5 — Multi-port DMA system

산출물:

- multi-HP memory map
- scatter/gather 또는 custom DMA engine
- 576 KiB logical weight ping/pong과 명시적 ownership controller
- descriptor queue

Gate:

- DDR stress test 무오류
- DMA/compute overlap counter 확인
- batch 8 weight reuse 확인
- Conv1 계산 중 Conv2 307,200 B weight preload 완료
- AXI read/write byte counter가 analytical schedule과 일치

### Phase 6 — Full AlexNet RTL and software

산출물:

- full-network scheduler
- Linux driver/UAPI
- persistent runtime
- board deployment package

Gate:

- C++ golden과 모든 layer byte-exact
- validation subset 결과 일치
- timeout/DMA/scheduler error 0

### Phase 7 — Performance and power sign-off

산출물:

- post-route timing/utilization/power reports
- board throughput/power sweep
- TOPS/W report
- 1시간 sustained reliability run

Gate:

- 250 MHz timing clean
- batch throughput 최소 목표 충족
- achieved TOPS/W 최소 목표 충족
- thermal/throttle/error 없음

## 8. Verification matrix

모듈별 testbench와 oracle 책임은 다음으로 고정한다.

| DUT/testbench | C++/scoreboard reference | 핵심 검증 |
|---|---|---|
| packed PE | `packed_mac_ref` | lo/hi sign correction, clear/last, INT32 extreme |
| local `M8xN8` skew | SV cycle queue + tag model | g/c delay, stall hold, flush, lane mask |
| `M32xN64` broadcast top | SV transaction scoreboard | partition fanout, tile tag, result count |
| window/RS feeder | `window_ref` | K11/5/3, stride 4/1, pad, row/tile boundary |
| weight DMA/tile buffer | `layout_ref` | K-major order, burst/tail, bank ownership, swap |
| postprocess | `quant_ref` | bias, rounding, negative shift, ReLU, saturation |
| max pool | `maxpool_ref` | `3x3/s2`, boundary와 backpressure |
| Conv tile/full layer | `conv2d_ref` | Conv1/2 및 random small shape byte-exact |
| FC tile/full layer | `linear_ref` | batch 1/8/16, FC6 K=9216, N tail 40 |
| scheduler/descriptor | `descriptor_ref` | loop/address, dependency, DMA error, timeout |
| full AlexNet | `alexnet_ref` + pre-generated vectors | 모든 layer hash와 final logits |

작은 operator는 DPI로 cycle마다/transaction마다 비교하고, full layer/network는
미리 생성한 `.bin + manifest + SHA-256` vector를 사용한다. 모든 ready/valid interface에
deterministic seed의 random backpressure를 주고 driver는 clock negedge에서 입력을
변경한다. Expected output은 FIFO queue에 넣고 실제 latency와 무관하게 tag/order/value를
비교한다. reset, mid-stream stall, output full, partial tile, DMA delayed completion을
각각 독립 test로 둔다.

필수 directed vector:

- all zero
- all `127`
- all `-128`
- alternating `127/-128`
- Conv1 padding corner/edge/center
- packed lo lane only valid
- packed hi lane only valid
- both packed lanes valid
- channel-tile boundary
- partial output-channel tile
- partial spatial tile
- accumulator positive/negative extreme
- rounding half-way positive/negative
- saturation immediately below/at/above limit
- Conv1 M8 patch-width 39와 stride-4 좌/우 경계
- Conv2 weight preload가 Conv1보다 빠른 경우와 늦은 경우
- ping/pong bank swap 직전/직후 stall 및 DMA error
- batch weight-major loop와 의도적인 image-major negative test
- full row zero, scattered element zero, packed-pair zero를 분리한 sparsity test

비교 단계:

```text
Python FP32
  -> Python INT8
  -> C++ bit-exact
  -> RTL operator
  -> RTL full model
  -> KV260 board
```

각 단계는 layer별 tensor hash와 final output을 모두 비교한다.

## 9. 주요 위험과 대응

| 위험 | 대응 |
|---|---|
| 모델 variant 불일치 | contract와 checkpoint hash 선고정 |
| packed accumulation field overflow | 매-cycle split 또는 최대 7-term chunk 준수 |
| INT32 이후 27-bit postprocess clip | range report 후 postprocess 재설계 |
| 1,024 DSP 배열 routing 실패 | 2/4 partition, local controller, floorplan |
| LUT accumulator 폭증 | DSP cascade 후보와 achieved TOPS/W 비교 |
| 단일 HP DDR 병목 | multi-HP DMA 및 batch reuse |
| FC weight bandwidth 병목 | weight tile을 batch 8/16에서 재사용 |
| global `M32xN64` skew/fanout timing 실패 | local `M8xN8` skew, registered tree, 2/4 partition |
| Conv1 K11/stride4 feeder starvation | M8당 39-pixel banked patch와 prefetch 검증 |
| weight bank 조기 swap으로 dot product 오염 | explicit owner/state와 compute-done/ready atomic swap |
| batch를 사용했지만 image-major loop로 weight 재독 | AXI byte counter와 weight-major schedule assertion |
| DMA overlap을 DDR byte 감소로 잘못 보고 | latency overlap counter와 physical read-byte counter 분리 |
| AlexNet에서 LeNet row-zero 효과 과대평가 | dense baseline 유지, granularity별 sparsity 실측 후 선택 |
| asymmetric activation에서 zero 검출 오류 | symmetric INT8 고정 또는 zero-point 비교/보상 재검증 |
| 높은 utilization로 Fmax 하락 | 10-15% routing margin 유지 |
| 300 MHz 전력/열 초과 | 250 MHz sign-off 후 clock sweep |
| ImageNet validation 데이터 부재 | 공식 ILSVRC2012 devkit/validation set 확보 후 FP32·INT8를 같은 loader로 측정 |

## 10. 저장소 확장 계획

기존 LeNet 검증 경로는 회귀 테스트로 보존한다.

```text
alexnet/
  model/
    alexnet_contract.yaml
  python/
    float_reference.py
    int8_reference.py
  cpp/
    quant_ref.cpp
    packed_mac_ref.cpp
    window_ref.cpp
    conv2d_ref.cpp
    maxpool_ref.cpp
    linear_ref.cpp
    layout_ref.cpp
    descriptor_ref.cpp
    alexnet_ref.cpp
    dpi_wrappers.cpp
  rtl/
    packed_mac/
    skew/
    rs_feeder/
    tile_engine/
    memory/
    scheduler/
  tb/
  vectors/
  software/
  reports/
```

AlexNet 변경으로 기존 `rtl/`, `tb/`, Stage04~06 LeNet board 결과가 깨지지 않도록 별도 top과 별도 build flow를 사용한다.

## 11. 즉시 실행 순서

1. AlexNet variant, checkpoint, preprocessing을 선택한다.
2. `alexnet_contract.yaml`을 작성하고 version 1을 고정한다.
3. FP32 및 실제 integer INT8 Python 모델을 완성한다.
4. calibration image에서 accumulator range, quantization 정확도와 element/pair/vector/block sparsity를 측정한다.
5. 공통 C++ bit-exact Conv/FC/Pool/requant/layout library와 얇은 DPI wrapper를 작성한다.
6. Conv1 `11x11x3`, stride/padding, M8 patch-width 39, packed two-lane vector를 생성한다.
7. 기존 split-every-cycle PE와 7-term DSP cascade를 동일 조건으로 합성한다.
8. logical `M8xN8` local-skew base tile을 bit-exact 검증하고 200/250 MHz timing을 확인한다.
9. registered tree로 base tile 32개를 `M32xN64`로 결합하고 partition별 timing을 측정한다.
10. K-major N64 weight packer와 576 KiB logical URAM ping/pong buffer를 구현한다.
11. Conv1 계산과 Conv2 DMA를 겹치고 readiness/FIFO 조건을 assertion과 counter로 검증한다.
12. layer/weight-major batch scheduler를 구현하고 AXI byte가 분석값과 일치하는지 확인한다.
13. batch 1 기능/latency 검증 후 batch 4/8/16 throughput과 `VCC_SOM` power를 측정한다.
14. dense 결과를 기준선으로 고정한 뒤 측정된 sparsity가 충분할 때만 CE gating 또는 block-sparse 확장을 진행한다.

## 12. 참고 자료

- AMD WP487, *8-Bit Dot-Product Acceleration*
- AMD UG579, *UltraScale Architecture DSP Slice User Guide*
- AMD DS987, *Kria K26 SOM Data Sheet*
- AMD PG201, *Zynq UltraScale+ MPSoC Processing System Product Guide*
- Alex Krizhevsky et al., *ImageNet Classification with Deep Convolutional Neural Networks*

이 계획의 최우선 산출물은 RTL이 아니라 versioned Python/C++ bit-exact 실행 규격이다. 이후의 OS/RS 비율, PE 크기, memory banking, DMA 구조는 그 규격을 바꾸지 않고 성능과 TOPS/W를 높이기 위한 구현 선택으로 다룬다.
