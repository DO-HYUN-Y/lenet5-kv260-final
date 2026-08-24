# AlexNet KV260 고처리량 가속기 구현 계획

- 작성일: 2026-08-24
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

## 1. RTL보다 먼저 고정할 실행 규격

### 1.1 Model contract

현재 성능 산정은 5 Conv + 3 FC, grouped convolution을 포함하는 고전 AlexNet을 기준으로 한다. 이 수치는 sizing 기준이며, RTL 의미론의 최종 기준은 아래 산출물로 별도 고정한다.

```text
model/alexnet_contract.yaml
```

계약 파일에는 최소한 다음 항목이 들어가야 한다.

- 입력 크기: 224 또는 227
- 입력 전처리와 channel 순서
- Conv1 padding, stride, output shape
- Conv2/4/5 group 수와 channel 연결
- LRN 사용 여부와 구현 위치
- Pool kernel, stride, padding
- classifier output class 수
- layer fusion 경계
- checkpoint SHA-256
- calibration dataset 버전과 seed
- 모델 및 vector format 버전

다음 항목이 확정되기 전에는 full RTL controller와 주소 맵을 고정하지 않는다.

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
- group convolution의 input/output channel 순서

비대칭 UINT8 activation을 채택하려면 기존 INT8 packing을 그대로 사용하지 않고 zero-point 보상식 또는 WP487 UINT8 방식을 별도로 검증한다.

### 1.3 Tensor ABI

다음 layout은 Python, C++, packer, RTL, driver가 공유하는 단일 ABI로 정의한다.

- activation layout: NCHW 또는 tiled-NCHW
- weight layout: OIHW 및 group 순서
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
- grouped Conv2D
- MaxPool
- LRN 또는 대체 operator
- FC/GEMM
- bias/ReLU/requantization
- tensor pack/unpack
- descriptor parser

통과 조건:

```text
Python INT8 tensor == C++ tensor
```

모든 layer에서 byte-exact가 되어야 하며, final logit만 비교하는 방식으로 대체하지 않는다.

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
| Conv2 grouped | 1,200 | 26-bit |
| Conv3 | 2,304 | 27-bit |
| Conv4/5 grouped | 1,728 | 26-bit |
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

### 4.2 Compute-array sizing

초기 공격적 target은 다음과 같다.

```text
M = 32 spatial/batch lanes
N = 64 output channels
packed MAC DSP = (32 / 2) * 64 = 1,024
postprocess DSP = 32 to 64
total DSP target = 1,056 to 1,088 / 1,248
```

대규모 단일 배열의 timing이 실패하면 2개 또는 4개의 독립 partition으로 나누고 각 partition에 로컬 weight/activation buffer와 controller를 둔다.

### 4.3 Resource budget

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

K26 DDR4는 64-bit, 2400 Mb/s이므로 raw bandwidth는 19.2 GB/s이다. AlexNet INT8 weight 약 60.95 MB를 매 이미지마다 읽으면 단일 이미지 모드가 memory-bound가 된다.

현재 단일 HP0 경로의 이론 대역폭은 다음과 같다.

```text
128 bit * 150 MHz = 2.4 GB/s
2.4 GB/s / 60.95 MB = 약 39 image/s
```

따라서 새 설계는 여러 128-bit HP/HPC port를 사용한다.

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

batch tensor 전체를 on-chip에 보관하지 않는다. weight tile은 유지하고 activation tile만 이미지별로 순환한다.

### 5.3 On-chip buffer

다음 buffer를 독립 banking한다.

- weight tile ping/pong
- activation tile ping/pong
- convolution line/window buffer
- INT32 partial-sum buffer
- bias/scale buffer
- descriptor queue

DMA와 compute를 겹치기 위해 각 ping/pong buffer는 명시적인 owner와 completion handshake를 가진다.

## 6. 성능 및 전력 목표

### 6.1 산정 기준

AlexNet sizing 기준:

```text
724,406,816 MAC/image
1,448,813,632 OPS/image
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
250 MHz: 1.024 TOPS, peak 706.8 image/s
300 MHz: 1.229 TOPS, peak 848.1 image/s
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

산출물:

- grouped Conv/Pool/FC/requant C++ model
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
- line/window feeder
- output-stationary PE tile
- INT32 partial-sum 처리
- postprocess 및 pooling

Gate:

- Conv1 전체 output byte-exact
- grouped Conv2 output byte-exact
- FC6 worst-depth test 통과
- backpressure/stall 주입 test 통과

### Phase 5 — Multi-port DMA system

산출물:

- multi-HP memory map
- scatter/gather 또는 custom DMA engine
- ping/pong ownership controller
- descriptor queue

Gate:

- DDR stress test 무오류
- DMA/compute overlap counter 확인
- batch 8 weight reuse 확인

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

필수 directed vector:

- all zero
- all `127`
- all `-128`
- alternating `127/-128`
- Conv1 padding corner/edge/center
- packed lo lane only valid
- packed hi lane only valid
- both packed lanes valid
- group boundary channel
- partial output-channel tile
- partial spatial tile
- accumulator positive/negative extreme
- rounding half-way positive/negative
- saturation immediately below/at/above limit

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
| 높은 utilization로 Fmax 하락 | 10-15% routing margin 유지 |
| 300 MHz 전력/열 초과 | 250 MHz sign-off 후 clock sweep |
| LRN throughput 저하 | PL 구현, PS 분할, 또는 model contract에서 제거 후 재학습 비교 |

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
    alexnet_golden.cpp
  rtl/
    packed_mac/
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
4. per-layer accumulator range와 quantization 정확도를 확인한다.
5. C++ bit-exact grouped Conv/FC/requant 모델을 작성한다.
6. Conv1 `11x11x3`, stride/padding, packed two-lane vector를 생성한다.
7. 기존 split-every-cycle PE와 7-term DSP cascade를 동일 조건으로 합성한다.
8. 250 MHz에서 resource, throughput, power estimate를 비교해 PE 구조를 선택한다.
9. 선택한 PE로 tile engine과 multi-HP DMA를 구현한다.
10. batch 1 기능 검증 후 batch 8/16 throughput과 `VCC_SOM` power를 측정한다.

## 12. 참고 자료

- AMD WP487, *8-Bit Dot-Product Acceleration*
- AMD UG579, *UltraScale Architecture DSP Slice User Guide*
- AMD DS987, *Kria K26 SOM Data Sheet*
- AMD PG201, *Zynq UltraScale+ MPSoC Processing System Product Guide*
- Alex Krizhevsky et al., *ImageNet Classification with Deep Convolutional Neural Networks*

이 계획의 최우선 산출물은 RTL이 아니라 versioned Python/C++ bit-exact 실행 규격이다. 이후의 OS/RS 비율, PE 크기, memory banking, DMA 구조는 그 규격을 바꾸지 않고 성능과 TOPS/W를 높이기 위한 구현 선택으로 다룬다.
