# AlexNet pure row stationary baseline

RS 구현을 위한 별도 폴더다. 초기 커밋은 구현 기준과 비교 조건을 고정한다.
현재 상태는 준비 단계이며 RTL/전체 추론 검증 결과를 뜻하지 않는다.

비교 기준 hybrid는 GitHub `854adea4d30e7861eae07f56df8f35966af31eb3`다.
IS baseline과 동일하게 논리 8×128, 물리 packed 4×128의 SA 자원을 사용하며,
원본 postprocessor 64 DSP, N8 output router와 입력/출력 뱅크 크기를 유지한다.
SA 목표는 512 packed DSP, 전체 연산부 목표는 576 DSP, KV260 200 MHz다.

RS는 PE에서 필터 행, 입력 행의 sliding window와 행 부분합을 재사용한다.
행별 1D convolution 결과를 공간적으로 합쳐 2D convolution을 계산한다.
필터 행을 담는 PE 레지스터와 1D 행 부분합의 지역 누산은 RS primitive의
일부다. 큰 weight URAM을 반복 재생하는 경로와 별도 WS/OS 모드 전환은
추가하지 않는다. FC는 kernel-height 1의 같은 primitive로 처리한다.

전체 AlexNet의 frozen INT8 weight/parameter, N8 layout, batch 1, pooling
1/2/5를 유지한다. 입력·가중치·부분합·출력 전송을 각각 세어 비교한다.
모델 추정, AXI-Stream valid byte와 물리 DDR burst 실측을 구분한다.
hybrid가 유리하도록 spill을 강제로 만들거나 메모리 용량을 달리하지 않는다.

구현 순서는 RS PE/SA, scheduler와 기존 후처리 연결, 동일 뱅크 및 DMA 서비스,
층별/전체 학습 모델 RTL 검증, 보드 빌드다. 검증한 범위와 미검증 범위를
보고서에 기록한다.

RS 정의의 기준은 [MIT Eyeriss project](https://eyeriss.mit.edu/)와
[Eyeriss ISCA 2016 발표](https://eems.mit.edu/wp-content/uploads/2016/06/eyeriss_isca_2016_slides.pdf)다.
