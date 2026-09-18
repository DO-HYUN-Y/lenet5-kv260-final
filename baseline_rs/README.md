# AlexNet pure row stationary baseline

GitHub hybrid `854adea4d30e7861eae07f56df8f35966af31eb3`와 비교하는 별도 RS 구현이다.
준비 폴더를 먼저 커밋한 뒤 `baseline/pure-row-stationary` 브랜치에서 구현했다.
검증 범위는 `reports/`와 `config/comparison_contract.json`에 기록한다.

논리 SA 크기 **8×128**, 물리 packed **4×128 / 512 DSP**를 유지한다. RS에서는
8개 수평 출력 window × 128개 필터 행 primitive로 매핑한다. 이는 자원 크기를
고정한 매핑이며, hybrid의 N축 128과 같은 PE 역할을 뜻하지 않는다.
원본 64 DSP postprocessor, N8 output router, 입력 2×4096×128-bit와 출력
2×512×64-bit ping-pong bank를 그대로 사용한다. 입력 bank의 **4 URAM은 유지**하고
weight replay URAM은 사용하지 않는다.

각 packed PE는 인접 window 두 개가 겹치는 입력 행 RF를 공유한다.
이 RF는 single-write / dual-read 분산 메모리다. 입력 word를 받아 주소를 decode한 뒤
low/high window 값을 두 사이클에 쓰고, 마지막 RF 쓰기가 끝난 후 command를 시작한다.
유효한 행 전체를 덮어쓰므로 RF 초기화는 필요하지 않고 MAC bubble 입력은 0으로 만든다. 같은 열의
네 packed PE는 하나의 필터 행 RF에서 tap 가중치를 전달받는다. PE는 해당
1D 필터 행의 tap만 signed19로 정확하게 지역 누산하고, 완료된 행 부분합은 7단 공간 reduction을
거쳐 signed20..26으로 합친다. 최대 행 누산 11×16384=180224는 signed19에 정확히 들어간다. 이후 K 행 블록의 continuation은 16 KiB 외부 psum BRAM에서
읽는다. 전체 출력의 장기 누산을 PE에 남기는 OS 모드, 여러 M 타일에서 큰
weight 타일을 replay하는 WS 모드, dataflow 전환 모드는 없다. 행 RF와 지역
행 누산은 RS primitive의 구성 요소다.

| Layer | 필터 행 길이 S | 한 번에 활성인 행 수 | M 타일 |
|---|---:|---:|---|
| Conv1 | 11 | 33 | 같은 출력 y의 최대 8개 x, stride 4 |
| Conv2 | 5 | 최대 128 | 같은 출력 y의 최대 8개 x |
| Conv3 / Conv4 / Conv5 | 3 | 최대 128 | 같은 출력 y의 최대 8개 x |
| FC6 | 6 | 128 | 1, pool5의 실제 CHW 6×6 행 |
| FC7 / FC8 | 1 | 128 | 1, 같은 primitive의 길이 1 |

Conv의 reduction 순서는 `(kernel_y, input_channel, kernel_x)`다. FC6의
flatten은 원본 CHW를 유지한다. 출력 행 경계에서 M 타일을 나누므로 마지막
M 타일은 7 / 3 / 5개다. 이 분할은 RS Conv 가중치 재적재량을 증가시키며,
비교 보고서에 그대로 반영한다. FC의 batch 1에서 추가 spatial input reuse를
가정하지 않는다.

입력 gather의 39×64-bit 행 버퍼(312-byte payload)는 겹치는 window와 N8의
8개 채널을 재사용한다. FC6는 한 N8 channel group의 36개 공간 word를 담는다.
요청 metadata는 handshake에서 저장하고, 두 검증 단계에서 주소·크기·행
정렬과 출력 행 경계를 검사한 다음 DDR 요청을 시작한다. Producer가 handshake
직후 request 신호를 바꾸어도 저장된 요청만 검사한다.
PE 입력 행 RF는 512×16-byte, 공유 filter RF는 최대 128×11-byte다. DSP 수와
공통 bank 용량을 고정했어도 RF/FF/LUT 전체 면적은 같다고 가정하지 않는다.

원본 학습 checkpoint, INT8 가중치/parameter, batch 1, N8 tensor layout과
pool1 / pool2 / pool5를 유지한다. 가중치는 OIHW를 RS 행 순서로 바꾸고 모든
바이트를 역변환하여 원본과 비교한다. 재학습·재양자화는 하지 않는다.

## 재현

저장소 루트에서 실행한다. 모델 폴더의 `board_manifest.json`과 logical
OIHW/NK 파일들은 원본 frozen board export를 사용한다.

```sh
python -m baseline_rs.export_row_stationary_weights --board-manifest /path/to/frozen/board_manifest.json --output-dir /path/to/rs-model
python -m baseline_rs.validate_row_stationary_inference --rs-manifest /path/to/rs-model/rs_manifest.json --board-manifest /path/to/frozen/board_manifest.json
vivado -mode batch -source baseline_rs/scripts/run_row_stationary_regressions.tcl
python baseline_rs/audit_row_stationary_traffic.py
python baseline_rs/run_row_stationary_full_rtl.py --model-root /path/to/rs-model --verilator /path/to/verilator
vivado -mode batch -source baseline_rs/scripts/synth_row_stationary_board.tcl
python -m unittest baseline_rs.test_row_stationary_export baseline_rs.software.runtime.test_row_stationary_board baseline_rs.test_verify_board_result
vivado -mode batch -source baseline_rs/board/scripts/build_kv260_pure_rs.tcl
```

원본 C++ golden은 `alexnet/cpp`에서 빌드한다. 별도 RS 수치 모델은 모든
signed19 행 누산, signed20..26 공간 tree, signed27 continuation과 postbias 범위를 검사하고 원본 accumulator와
출력을 비교한다. 전체 RTL 검증은 실제 **512 packed PE**와 production bank,
DMA, postprocessor, pool 회로를 사용한다. 외부 DMA/DDR만 testbench 서비스다.
각 층과 pool 결과의 모든 출력 바이트를 검사하고, 다음 층은 실제 RTL 출력
메모리를 읽는다. C++ 연산으로 SA를 대체하지 않는다.

## 보드

빌드 출력은 `baseline_rs/board/build/output/alexnet_pure_rs_kv260.bit`와 `.xsa`다.
200 MHz setup/hold, routing, DRC 및 512 SA DSP / 576 total DSP / 4 input URAM
검사가 통과해야 최종 출력으로 복사한다. weight DMA는 unaligned RS row
slice를 위해 DRE를 켠다. main read / main write / weight read는 HP0 / HP1 / HP3다.

원본 coherent allocator/kernel driver와 PS 주소 map을 유지한다. camera DMA는
추론에 사용하지 않고 quantized N8 raster를 직접 gather한다. RS ID는
`0x52530100`, build는 `0x088000c8`다. 기존 hybrid runtime 대신 아래 runner를 쓴다.

```sh
python -m baseline_rs.software.runtime.alexnet_row_stationary_board --model /path/to/rs-model --input /path/to/input_n8.bin --report /path/to/rs-board-result.json
python -m baseline_rs.verify_board_result --report /path/to/rs-board-result.json --vector-root baseline_rs/build/rs_trained_vectors
```

Golden 검증을 위해서는 위 numerical validation에서 만든 `input_n8.bin`을
보드에 넣는다. Verifier는 보드 ID, 모델 SHA, 입력 SHA, 1000개 FC8 출력 바이트,
전체 graph와 전송량 카운터를 대조한다. 임의의 다른 입력에 이 golden을 사용하지 않는다.

`reports/traffic.json`의 hybrid 숫자는 실행된 RTL scheduler descriptor다.
전체 RTL의 main/weight/gather 카운터는 accepted AXI-Stream valid byte다.
물리 DDR burst·alignment·refresh·arbitration은 보드에서 따로 측정해야 한다.
부분합은 16 KiB BRAM에서 처리하며 인위적인 DRAM spill은 더하지 않는다.
가중치 전송량 절감만으로 전체 DRAM 절감률이나 실제 추론 속도를 결론내리지 않는다.

RS primitive 정의는 [Eyeriss ISCA 2016 논문](https://eems.mit.edu/wp-content/uploads/2016/04/eyeriss_isca_2016.pdf)의 필터/입력/부분합 행 재사용을 따른다. 이 구현은
8×128 자원에 맞춘 별도 매핑이며 Eyeriss RTL을 그대로 복제한 것이 아니다.
