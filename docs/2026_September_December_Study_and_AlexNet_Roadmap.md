# 2026년 9월–12월 CS 기초 학습 및 AlexNet RTL 개발 로드맵

- 작성일: 2026-08-28
- 기간: 2026-09-01 ~ 2026-12-20, 이후 12월 말은 보충 기간
- 기준 저장소: `DO-HYUN-Y/lenet5-kv260-final`
- 기준 프로젝트: AlexNet INT8 KV260 고처리량 가속기
- 기본 학습량: 주 18시간
- 최종 목표: 강의 완강 자체가 아니라 설명 가능하고 자동 검증되는 코드와 RTL을 남기는 것

## 0. 계획 요약

이 계획은 알고리즘, 딥러닝, 운영체제를 따로 공부하는 시간표가 아니다. 세 과목에서
배운 내용을 AlexNet 프로젝트의 Python, C++, SystemVerilog, testbench 코드에 즉시
적용하는 프로젝트 중심 학습 계획이다.

```text
MIT 6.006                  -> 자료구조, 복잡도, 정확성 증명, 구현 습관
Stanford CS231n            -> CNN/AlexNet 연산과 tensor 의미
Berkeley CS162             -> C/C++, 메모리, 동시성, I/O, 성능 사고
                                  |
                                  v
Python FP32/INT8 reference -> C++ bit-exact golden -> RTL -> self-checking TB
```

저장소는 이미 AlexNet Phase 0~2에 해당하는 model/numeric contract, Python reference,
C++ bit-exact golden과 pre-RTL sign-off를 갖추고 있다. 따라서 9월에 reference를 처음부터
다시 만드는 대신 기존 코드를 읽고 테스트를 추가하면서 구조를 이해한다. 10월부터는
packed MAC, local systolic-array tile, output router, postprocess와 RS feeder 순서로 RTL을
작성한다.

## 1. 사용할 강의

### 1.1 알고리즘

- [MIT 6.006 Introduction to Algorithms, Spring 2020 - YouTube](https://www.youtube.com/watch?v=ZA-tUyM_y7s&list=PLUl4u3cNGP63EdVPNLG3ToM6LaEUuStEY)
- [MIT OpenCourseWare 강의·노트·과제](https://ocw.mit.edu/courses/6-006-introduction-to-algorithms-spring-2020/)

우선 범위는 Lecture 1~20이다. Problem Session은 1, 2, 4, 5, 8을 우선한다.

### 1.2 딥러닝 및 컴퓨터 비전

- [Stanford CS231n Deep Learning for Computer Vision, Spring 2025 - YouTube](https://www.youtube.com/watch?v=2fq9wYslV0A&list=PLoROMvodv4rOmsNzYBMe0gJY2XS8AQg16)
- [CS231n 2025 공식 일정과 강의 자료](https://cs231n.stanford.edu/2025/schedule.html)

이번 기간의 필수 범위는 Lecture 1~6과 Python/NumPy, PyTorch review다. Lecture 5의
convolution/pooling과 Lecture 6의 AlexNet/VGG/ResNet 구조를 프로젝트에 직접 연결한다.
RNN, Transformer, detection, diffusion 등 Lecture 7 이후 내용은 12월 이후로 미룬다.

### 1.3 운영체제

- [UC Berkeley CS162 Operating Systems and Systems Programming - YouTube](https://www.youtube.com/watch?v=pPzVV2kkGHc&list=PLF2K2xZjNEf97A_uBCwEl61sdxWVP7VWC)
- [CS162 강의 목차와 노트](https://hrus.in/ocw/CS162/)

이번 기간의 우선 범위는 Lecture 1~18이다. 프로세스/스레드, 동기화, 스케줄링,
가상메모리, TLB, I/O를 우선하고 파일시스템과 분산시스템 Lecture 19~23은 12월 이후로
미룬다. 가상메모리와 I/O 부분은 이후 gem5/CXL 코드 분석의 기초로 사용한다.

## 2. 현재 프로젝트 기준점

2026-08-28 기준 다음 항목은 이미 완료되어 있다.

- `alexnet/alexnet_contract.yaml`: torchvision AlexNet의 layer/numeric 계약
- `alexnet/model.py`: FP32 모델과 layer 흐름
- `alexnet/int8_reference.py`: Python INT8 integer reference
- `alexnet/cpp/`: Conv, Pool, FC, quant, packed MAC, SA, layout, descriptor golden
- `alexnet/test_cpp_golden_against_pytorch.py`: Python/C++ cross-language parity
- `alexnet/PRE_RTL_SIGNOFF.md`: 정확도, numeric width, SA/buffer/router 결정
- `docs/AlexNet_KV260_High_Throughput_Implementation_Plan.md`: 전체 구현 및 gate 계획

따라서 이번 학습 기간의 프로젝트 기준선은 다음과 같다.

```text
완료: contract -> Python FP32/INT8 -> C++ bit-exact -> pre-RTL sign-off
진행: 기존 코드 이해 및 테스트 확장
다음: packed MAC RTL -> M8xN8 local tile -> router/postprocess -> RS feeder
```

## 3. 12월 최종 산출물

12월 20일까지 다음 결과를 목표로 한다.

1. 기존 Python/C++ AlexNet 코드의 호출 흐름과 numeric contract 설명 문서
2. C++ golden test의 directed/random corner case 추가
3. AlexNet 전용 packed MAC RTL과 self-checking testbench
4. local logical `M8xN8` systolic-array tile RTL과 skew/holding 검증
5. N8 output router 및 requant/ReLU/saturation RTL 검증
6. 작은 Conv tile의 window/weight/SA/postprocess 통합
7. ready/valid backpressure, M/N/K tail, reset, timeout regression
8. OOC synthesis를 통한 DSP/LUT/FF 및 timing 측정
9. Python/C++/RTL 결과를 재현하는 실행 명령과 README
10. 설계 선택, 실패 사례, 성능 및 남은 위험을 정리한 최종 보고서

Full AlexNet 보드 추론은 stretch goal이다. 이번 기간의 필수 성공 기준은 전체 네트워크를
급하게 연결하는 것이 아니라, 이후 확장 가능한 base tile과 검증 체계를 정확하게 닫는
것이다.

## 4. 주간 시간 배분

주 18시간 기준이다.

| 요일 | 시간 | 작업 |
|---|---:|---|
| 월 | 2.5시간 | MIT 6.006 강의, 문제 1개, Python 구현 |
| 화 | 3시간 | CS231n 강의, tensor 수식 정리, PyTorch/NumPy 실습 |
| 수 | 3시간 | CS162 강의, C/C++ 또는 Linux 미니 실습 |
| 목 | 3시간 | AlexNet Python/C++ 코드 읽기와 테스트 추가 |
| 금 | 3시간 | RTL 또는 self-checking testbench 구현 |
| 토 | 3.5시간 | 통합 regression, 코드 리뷰, 주간 기록 |
| 일 | 휴식 | 밀린 작업이 있을 때만 1시간 이내 보충 |

강의 시청은 전체 시간의 30%를 넘기지 않는다. 강의 1시간마다 최소 1시간의 구현,
문제 풀이 또는 테스트 작성을 남긴다.

시간이 주 10~12시간으로 줄어들면 프로젝트 시간을 먼저 보존하고 Problem Session과
선택 강의를 줄인다. 강의 진도를 맞추기 위해 테스트를 생략하지 않는다.

## 5. 16주 상세 일정

### 5.1 9월: 기존 reference 이해와 검증 코드 작성

| 주차 | 강의 | 프로젝트 작업 | 완료 증거 |
|---|---|---|---|
| 1주차<br>9/1~9/6 | 6.006 L1<br>CS231n L1/NumPy review<br>CS162 L1 | 전체 저장소 실행 경로 재현, `model.py -> INT8 -> C++` 호출 지도 작성 | Python unit test, CTest, full-network parity 명령과 결과 기록 |
| 2주차<br>9/7~9/13 | 6.006 L2~3<br>CS231n L2<br>CS162 L2~3 | `model.py`, `alexnet_contract.yaml`, tensor shape와 레이어 경계 분석 | Conv/Pool/FC shape를 손으로 계산한 코드 읽기 노트 |
| 3주차<br>9/14~9/20 | 6.006 L4<br>CS231n L3<br>CS162 L4~5 | `quant_ref`, `conv2d_ref`, `maxpool_ref`, `linear_ref` C++ 호출 추적 | 함수별 입력/출력/불변식/오류 조건 표 |
| 4주차<br>9/21~9/27 | 6.006 L5~6<br>CS231n L4<br>CS162 L6 | C++ golden에 overflow, rounding, tail, invalid descriptor test 추가 | 신규 directed/random test와 실패 재현 seed |

#### 9월 통과 조건

- Python FP32, Python INT8, C++ golden의 역할 차이를 설명할 수 있다.
- Conv1의 `K=3x11x11=363`과 출력 shape를 직접 계산할 수 있다.
- signed INT8, INT32 accumulator, signed-27 x signed-18 postprocess 계약을 설명할 수 있다.
- C++ test 실패를 디버거 또는 최소 재현 입력으로 좁힐 수 있다.
- 기존 테스트를 깨뜨리지 않고 새로운 corner case를 추가한다.

### 5.2 10월: packed MAC, local SA와 testbench

| 주차 | 강의 | 프로젝트 작업 | 완료 증거 |
|---|---|---|---|
| 5주차<br>9/28~10/4 | 6.006 L7~8<br>CS231n L5<br>CS162 L7 | packed INT8 MAC 수식과 cycle contract 작성, AlexNet용 `packed_pe` RTL 초안 | C++ `packed_mac_ref`와 directed vector 일치 |
| 6주차<br>10/5~10/11 | 6.006 L9~10<br>CS231n L6<br>CS162 L8 | packed PE self-checking TB, accumulator clear/hold/reduce 검증 | random 10,000 product pair, reset/overflow/hold test 통과 |
| 7주차<br>10/12~10/18 | 6.006 L11<br>CS231n L2~4 복습<br>CS162 L10 | local logical `M8xN8` SA와 tile-local skew 구현 | C++ `sa_tile_ref`/`skew_ref` 대비 cycle 및 값 일치 |
| 8주차<br>10/19~10/25 | 6.006 L12~13<br>PyTorch review/AlexNet 논문<br>CS162 L11~12 | result holding, `reduce_last`, backpressure와 다음 tile 시작 검증 | holding overwrite assertion, stall 중 stable output 확인 |
| 9주차<br>10/26~11/1 | 6.006 L14<br>CS231n CNN 복습<br>CS162 L13 | N8 output router 및 FIFO 동작 구현/검증 | full-FIFO same-cycle pop/push, tail mask, 독립 stall 통과 |

#### 10월 통과 조건

- sequential logic에는 nonblocking assignment를 사용한다.
- synthesizable RTL의 data path에 임의 `#delay`를 사용하지 않는다.
- reset 후 output/valid에 `X/Z`가 남지 않는다.
- ready가 내려간 동안 valid payload와 tag가 안정적으로 유지된다.
- random seed가 고정되고, 실패 vector를 한 명령으로 재현할 수 있다.
- packed PE와 M8xN8 tile의 OOC synthesis resource를 처음 측정한다.

### 5.3 11월: postprocess, RS feeder와 작은 Conv tile 통합

| 주차 | 강의 | 프로젝트 작업 | 완료 증거 |
|---|---|---|---|
| 10주차<br>11/2~11/8 | 6.006 L15<br>CS231n L5~6 복습<br>CS162 L14 | signed-27 x signed-18 requant, rounding, ReLU, saturation RTL | `quant_ref`와 boundary/random bit-exact 일치 |
| 11주차<br>11/9~11/15 | 6.006 L16<br>float/INT8 비교<br>CS162 L15 | RS window feeder의 padding/stride/M-tail 구현 | Conv1 `11x11/s4/p2`, 일반 `3x3`, tail vector 통과 |
| 12주차<br>11/16~11/22 | 6.006 L17<br>CS162 L16 | weight tile 공급과 local SA 연결, 작은 Conv tile 통합 | window -> SA -> postprocess end-to-end bit-exact |
| 13주차<br>11/23~11/29 | 6.006 L18<br>CS162 L17 | descriptor, K/M/N loop, 주소 계산과 backpressure 통합 | invalid descriptor, K/M/N tail, timeout regression 통과 |

#### 11월 통과 조건

- Python/C++/RTL 세 구현이 같은 rounding과 saturation 순서를 사용한다.
- padding numeric zero와 transport valid를 구분한다.
- Conv1과 3x3 convolution을 같은 parameterized 경로로 검증한다.
- tile 경계에서 accumulator, descriptor, FIFO tag가 섞이지 않는다.
- waveform을 전부 눈으로 확인하지 않아도 self-checking TB가 오류를 검출한다.

### 5.4 12월: resource/timing gate와 최종 정리

| 주차 | 강의 | 프로젝트 작업 | 완료 증거 |
|---|---|---|---|
| 14주차<br>11/30~12/6 | 6.006 L19<br>CS162 L18 | M8xN8/후처리/router OOC synthesis, resource와 timing 분석 | DSP/LUT/FF/BRAM/URAM, WNS/TNS 표 |
| 15주차<br>12/7~12/13 | 6.006 L20~21<br>CS162 L19 선택 | regression 자동화, lint, 실패 test 최소화, 문서 보완 | 한 명령의 전체 unit/integration regression |
| 16주차<br>12/14~12/20 | 전체 복습 | 최종 demo, 설계 리뷰, Phase 4 진입 판단 | 보고서, 재현 명령, Git tag 또는 명확한 milestone commit |
| 보충<br>12/21~12/31 | 부족한 부분 보충 | 버그 수정, 추가 최적화, 다음 분기 계획 | 미해결 issue와 우선순위 갱신 |

## 6. 과목별 코딩 과제 규칙

### 6.1 알고리즘

매주 최소 문제 1개를 다음 형식으로 남긴다.

```text
문제 정의
입력/출력 계약
선택한 자료구조
정확성 근거 또는 loop invariant
시간/공간 복잡도
Python 구현
격주 C++ 구현
boundary test
```

프로젝트에 직접 적용할 예시는 다음과 같다.

- dynamic array와 tensor storage
- hashing과 manifest/SHA 검증
- heap과 작업 우선순위
- graph와 module dependency
- dynamic programming의 subproblem 정의
- 복잡도 분석과 tile loop 비용 계산

### 6.2 딥러닝

프레임워크 호출만 외우지 않고 다음 값을 직접 계산한다.

- convolution output shape
- kernel dot-product K
- MAC/image와 OPS/image
- stride/padding이 window 주소에 미치는 영향
- pooling output shape
- weight/activation tensor layout
- FP32와 INT8 사이의 scale, bias, multiplier, shift 관계

CS231n Lecture 5~6 이후에는 저장소의 실제 `alexnet_contract.yaml`과 비교해 같은 개념이
어떻게 코드와 RTL 계약으로 내려오는지 기록한다.

### 6.3 운영체제

강의 주제마다 작은 C/C++ 또는 Linux 실습을 하나씩 수행한다.

- process/thread 생성과 종료
- file descriptor와 binary file I/O
- pipe 또는 producer/consumer queue
- race condition과 mutex/semaphore
- 간단한 scheduling simulator
- virtual address, page, TLB 계산
- `mmap`을 이용한 tensor/vector 파일 접근
- 순차/무작위 I/O 성능 비교

실습 결과는 향후 gem5/CXL 분석과 연결해 메모리 요청, 주소 범위, NUMA, page placement,
I/O queue에 대한 질문을 남긴다.

## 7. 언어별 성장 기준

### 7.1 Python

- tensor shape와 dtype을 assert한다.
- 함수는 한 가지 역할만 갖도록 나눈다.
- deterministic seed를 사용한다.
- `unittest` 또는 기존 test 구조로 regression을 남긴다.
- vector와 manifest에는 shape, dtype, byte order, hash를 기록한다.

### 7.2 C++

- raw pointer의 소유권을 불분명하게 두지 않는다.
- `const`, reference, RAII와 표준 container를 의도적으로 사용한다.
- header에는 계약을, source에는 구현을 둔다.
- overflow 가능성을 넓은 intermediate type과 explicit check로 처리한다.
- CTest와 Python parity 양쪽에서 같은 corner case를 검증한다.

### 7.3 SystemVerilog

- datapath와 control을 분리한다.
- 모든 register의 reset/enable/hold 동작을 정의한다.
- parameter와 localparam의 의미를 문서화한다.
- signed width 확장과 truncation을 암시적으로 맡기지 않는다.
- valid/ready, tag, mask, tail의 cycle 정렬을 assertion한다.
- testbench가 expected result를 자동 비교하고 timeout을 검출하게 한다.

## 8. RTL 모듈 Definition of Done

모듈 하나를 완료했다고 판단하려면 다음 항목이 모두 있어야 한다.

- 입력/출력 및 cycle contract
- Python 또는 C++ golden source
- directed normal-case test
- signed minimum/maximum boundary test
- randomized test
- reset 중/직후 test
- backpressure/hold test
- tail/mask test
- timeout 및 deadlock 검출
- deterministic seed와 실패 vector 저장
- assertion 및 self-checking scoreboard
- standalone synthesis 결과
- latency와 resource 기록
- 실행 방법 문서

waveform을 한 번 확인한 것만으로는 완료 처리하지 않는다.

## 9. 주간 기록 형식

매주 토요일 아래 형식으로 `docs/weekly/` 또는 GitHub issue에 기록한다.

```markdown
# YYYY-MM-DD 주간 기록

## 학습
- 알고리즘:
- 딥러닝:
- 운영체제:

## 구현
- 변경 파일:
- 추가 테스트:
- 통과 결과:

## 실패와 원인
- 증상:
- 최소 재현 조건:
- 원인:
- 수정:

## 수치
- test count:
- mismatch count:
- latency/cycle:
- synthesis resource/timing:

## 다음 주 첫 작업
- [ ] 하나의 구체적인 시작 작업
```

## 10. 프로젝트 재현 명령

실제 환경에 맞게 경로를 설정한 뒤 기준선이 계속 통과하는지 확인한다.

```powershell
# Python 구조 및 INT8 reference
& $alexnetPython -m unittest alexnet.test_model -v
& $alexnetPython -m unittest alexnet.test_int8_reference -v

# C++ golden
cmake -S alexnet/cpp -B alexnet/cpp/build -G "MinGW Makefiles"
cmake --build alexnet/cpp/build
ctest --test-dir alexnet/cpp/build --output-on-failure

# Python/C++ cross-language parity
& $alexnetPython -m unittest alexnet.test_cpp_golden_against_pytorch -v
```

RTL 개발이 시작되면 각 모듈의 test script를 `scripts/`에 두고, 최종적으로 여러 script를
호출하는 top-level regression 명령을 추가한다.

## 11. 중간 점검일

### 9월 27일: 코드 이해 gate

- 기존 Python/C++ 모델의 호출 구조를 설명할 수 있는가?
- 테스트 하나를 스스로 추가하고 실패를 재현할 수 있는가?
- numeric width와 rounding contract를 설명할 수 있는가?

### 10월 25일: local tile gate

- packed PE와 local M8xN8 tile이 bit-exact인가?
- reset, hold, reduce, backpressure assertion이 있는가?
- OOC resource를 최소 한 번 측정했는가?

### 11월 29일: 작은 Conv 통합 gate

- window, weight, SA, postprocess가 하나의 self-checking TB에서 통과하는가?
- Conv1 geometry와 일반 3x3 geometry를 모두 처리하는가?
- K/M/N tail과 stall을 자동 검증하는가?

### 12월 20일: 학기 종료 gate

- 다른 사람이 문서만 보고 테스트를 재현할 수 있는가?
- C++/RTL 코드를 함수·모듈 단위로 설명할 수 있는가?
- measured resource/timing을 근거로 다음 배열 크기를 판단할 수 있는가?
- 통과하지 못한 항목이 숨겨지지 않고 issue로 남아 있는가?

## 12. 우선순위와 금지 사항

우선순위는 다음과 같다.

```text
정확한 contract
  > 자동 검증
  > 이해 가능한 작은 모듈
  > resource/timing 측정
  > 큰 배열과 전체 네트워크 통합
```

다음 행동은 피한다.

- 강의를 틀어놓고 구현 없이 진도만 기록하기
- golden model 없이 RTL부터 작성하기
- 한두 개 hand-written vector만 통과하고 완료 처리하기
- fixed-point width와 rounding을 코드마다 다르게 정의하기
- waveform 눈검사만으로 regression을 대체하기
- 성능을 측정하지 않고 PE 개수만 늘리기
- 기존 LeNet RTL을 이해하지 않은 채 AlexNet에 그대로 복사하기
- 실패한 seed와 조건을 기록하지 않기

## 13. 2027년 이후 연결

이 계획이 끝난 뒤 다음 순서로 확장한다.

1. CS162 Lecture 19~23: 파일시스템, transaction, 네트워크
2. CS231n Lecture 7 이후: Transformer, detection, generative model
3. AlexNet multi-port DMA와 activation/weight ping-pong
4. full partition/full-shell implementation 및 KV260 board bring-up
5. gem5 memory request path 분석
6. CXL Type 3 memory expansion과 tiered-memory 실험

운영체제의 virtual memory/I/O, 알고리즘의 비용 분석, AlexNet 프로젝트의 실제 memory
traffic 측정을 연결해 이후 gem5/CXL 연구의 기반으로 사용한다.
