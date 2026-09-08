# AlexNet RTL

This tree is separate from the verified LeNet RTL in the repository root. It
implements the frozen contracts in `alexnet_contract.yaml` and
`PRE_RTL_SIGNOFF.md` without changing the LeNet top or build flow.

## Phase 3 bring-up order

1. `packed_mac/alexnet_packed_pe.sv`: U0 fixed-GEMM, split-every-cycle packed
   MAC, signed-27 accumulator, INT32 result ABI, one-entry result holding.
2. `sa/alexnet_sa_m4n8.sv`: logical M4xN8 base tile (physical 2x8 packed
   PEs), with tile-local skew, systolic hops, row-shared control alignment,
   and independent PE holdings.
3. `result/alexnet_m4n8_result_scanner.sv`: serialize packed holdings into
   M-ordered N8 accumulator beats with M/N tails and backpressure.
4. `result/alexnet_n8_output_router.sv`: independent 64-entry N8/64-bit
   packet FIFO with descriptor tags and full-FIFO pop/push turnover.
5. `postprocess/alexnet_n8_requant.sv`: five-stage, eight-lane N-stationary
   requantization between scanner and router, with one DSP48E2 per lane.
6. `integration/alexnet_m4n8_n8_output_slice.sv`: atomic scanner-requant-router
   integration with end-to-end FIFO backpressure.
7. `integration/alexnet_m4n8_base_datapath.sv`: unchanged M4xN8 SA connected
   to the output slice, from backpressured K issue through tagged INT8 packets.
8. `pool/alexnet_n8_maxpool3x3.sv`: independent N8 streaming
   3x3/stride-2/padding-0 max-pool with one BRAM36 line buffer.
9. `memory/alexnet_n8_activation_bank.sv`: reusable 512x64-bit N8 bank with
   explicit write/read ownership and one BRAM36 payload.
10. `feeder/alexnet_n8_rs_m4_feeder.sv`: raster N8 to row-local M4 K-major
    windows for K11/K5/K3, with five BRAM36 ring banks and spatial tails.
11. `control/alexnet_m4n8_rs_issue_controller.sv` and
    `integration/alexnet_m4n8_rs_datapath.sv`: context-gated, lockstep
    activation/weight K issue from raster input through final INT8 packets.
12. `memory/alexnet_n8_weight_tile_bank.sv`: resident 968x64-bit N8 weight
    tile with context-matched repeatable K replay and explicit release.
13. `integration/alexnet_m4n8_rs_resident_weight_datapath.sv`: fill one weight
    tile once and replay it for every spatial M group in one input-channel
    chunk, with frame-long ownership and descriptor-context gating.
14. `memory/alexnet_n8_int32_partial_sum_bank.sv`: 512x256-bit N8 signed-INT32
    first/continuation/final chunk accumulation with ordered final emission.
15. `integration/alexnet_m4n8_n8_accum_output_slice.sv`: scanner, 512-word
    partial-sum bank, final-only requantization, and router integration with
    deterministic raster metadata reconstruction.
16. `integration/alexnet_m4n8_accum_base_datapath.sv`: unchanged SA connected
    to the accumulator-aware output slice, with multi-chunk ownership and
    pending-configuration progress guarantees.
17. `integration/alexnet_m4n8_rs_resident_weight_accum_datapath.sv`: unchanged
    feeder/SA with resident weights and one-bank cross-chunk accumulation.
18. `memory/alexnet_n8_int32_partial_sum_bank_pair.sv` plus the dual-accumulator
    integration wrappers: fixed 512/217 conv2 raster segmentation.
19. `memory/alexnet_n8_activation_pingpong.sv`: two unchanged activation banks,
    ordered READY queue, direct/pooled source selection, and cross-bank overlap.
20. `memory/alexnet_n8_activation_dual_segment_pingpong.sv`: two unchanged
    ping-pong units composed into 1,024-word logical A/B sets with a fixed
    512-word segment boundary.
21. `integration/alexnet_m4n8_rs_activation_resident_weight_dual_accum_datapath.sv`:
    ordered activation metadata, registered descriptor validation, and atomic
    activation-read/RS launch without changing either child datapath.
22. `dma/alexnet_n8_dma_ingress.sv`: one registered 128-bit AXI4-Stream beat
    unpacked into two 64-bit N8 activation or resident-weight words, with
    owner-safe descriptor validation and exact `TKEEP/TLAST` checking.
23. `integration/alexnet_m4n8_rs_dma_activation_resident_weight_dual_accum_datapath.sv`:
    real DMA-to-activation/weight owner dispatch, tagged atomic compute launch,
    and sticky DMA-error launch interlock around unchanged child blocks.
24. `dma/alexnet_n8_dma_result_egress.sv`: two-word low-first 64-to-128-bit
    result packing, exact odd tail, router-metadata validation, deterministic
    error drain, and first/last tile-tag completion status.
25. `integration/alexnet_m4n8_rs_dma_io_activation_resident_weight_dual_accum_datapath.sv`:
    direct router-to-result-DMA wiring, descriptor-before-consumption ordering,
    composite input/output DMA error interlock, and full-loop idle ownership.
26. `control/alexnet_dma_chunk_scheduler.sv`: one registered software command
    sequenced through activation MM2S, stale-weight release, weight MM2S,
    final-result S2MM arming, chunk execution, retirement, and recoverable
    fault handling.
27. `integration/alexnet_m4n8_rs_dma_scheduled_io_datapath.sv`: scheduler-owned
    activation/weight MM2S descriptors, final-result S2MM descriptor, weight
    release, and chunk launch around the unchanged full DMA loop. Non-final
    commands retire at a quiescent chunk boundary with their accumulator
    transaction open; the final command waits for full pipeline idle.
28. `feeder/alexnet_n8_fc_m4_issuer.sv`: transpose stored
    `[K-block][M][K-lane]` N8 activations into M4 K cycles, synchronize one
    resident `[K][N-lane]` weight replay, and drive the unchanged SA
    `tile_start/issue` boundary with M/N/K tails.
29. `integration/alexnet_m4n8_fc_resident_weight_accum_datapath.sv`: validated
    FC chunk ownership, one resident-weight replay per chunk, cross-chunk
    INT32 accumulation, final-only requantization, and full-output retirement.
30. `integration/alexnet_m4n8_fc_activation_resident_weight_accum_datapath.sv`:
    one consuming activation bank, validated padded FC input fills, K-tail
    read-mask reconstruction, and reject-safe compute/read ownership.
31. `integration/alexnet_m4n8_fc_dma_io_datapath.sv`: validated 128-bit input
    DMA dispatch, automatic final-result descriptors, and completion only
    after all S2MM-facing AXIS beats transfer.
32. Runtime N8 output placement through the FC wrapper/router chain, with
    matching registered final-result DMA descriptors and a fixed-mode default.
33. `control/alexnet_fc_layer_controller.sv`: complete FC6/7/8 N8/K-chunk
    scheduling, parameter validation, logical read/result service requests,
    and final completion gated by both the core and the external result sink.
34. `integration/alexnet_m4n8_fc_layer_datapath.sv`: that controller owns one
    unchanged runtime-placement FC DMA datapath, with no extra SA or BRAM.
35. Add Conv1's direct 50,176-word activation stream, extend the common INT32
    accumulator to 4,096 words, and numerically verify its full 55x55 output.
36. `control/alexnet_graph_controller.sv`: fixed Conv1..Conv5/FC6..FC8 root
    order with one drained Conv-to-FC shared-owner handoff.
37. `feeder/alexnet_pool5_fc6_flatten_reader.sv`: gather all 9,216 Pool5
    scalars from N8 tile-major storage into FC6 channel-major N8 chunks.
38. `control/alexnet_conv_layer_controller.sv`: expand all five Conv jobs into
    144 N8 tiles and 3,912 checked shared-compute commands.
39. `integration/alexnet_graph_compute_orchestrator.sv` and
    `integration/alexnet_m4n8_graph_compute_top.sv`: connect Conv1..FC8 graph
    control, the drained Conv-to-FC handoff, and the one shared compute top.
40. Connect one reused Pool1/2/5 pool/bypass service, a two-RAMB36 Pool5 cache,
    and automatic Pool5-to-FC6 flatten injection.
41. Connect graph control, shared compute, pooling/storage, and FC6 injection
    in one `alexnet_m4n8_graph_data_top`; pipeline the physical DDR address
    planner and validate its complete fixed AlexNet descriptor space.
42. Add the physical DMA descriptor bridge, parameter-record router/loader,
    post-pool S2MM tile scheduler, and one AXI DMA simple-mode control owner.
43. Add the PS-facing AXI-Lite register bank and reusable accelerator IP top.
44. Package the accelerator and camera adapter IPs; connect ZynqMP PS, DDR,
    two AXI DMA instances, 200 MHz clock/reset, and IRQ in the KV260 block
    design; then generate a timing-clean bitstream and XSA.
45. Build the Linux USB-camera runtime and trained camera-to-terminal
    classification demonstration.
46. Revisit PE resources later, then expand the same tile boundary once to
    M8xN8.
47. Run every OOC resource/timing measurement at the 200 MHz baseline only.

The packed PE deliberately receives already aligned `mac_valid`, `acc_clear`,
`reduce_last`, and `lane_mask`. The local tile owns one shared four-enabled-
cycle DSP-alignment tap per physical row, avoiding a four-bit tag pipeline in
every PE. M4xN8 preserves the N8 boundary; the planned M8xN8 expansion only
doubles `PHYS_ROWS` from two to four.

Run the bit-exact C++ DPI regression from the repository root:

```bash
vivado -mode batch -source alexnet/scripts/run_alexnet_packed_pe.tcl
```

Run the 200 MHz OOC implementation:

```bash
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_packed_pe.tcl
```

Run the M4xN8 DPI regression and its 200 MHz OOC implementation:

```bash
vivado -mode batch -source alexnet/scripts/run_alexnet_sa_m4n8.tcl
vivado -mode batch -source alexnet/scripts/synth_impl_alexnet_sa_m4n8.tcl
```

Run the scanner/router DPI regressions and 200 MHz OOC implementations:

```bash
vivado -mode batch -source alexnet/scripts/run_alexnet_m4n8_result_scanner.tcl
vivado -mode batch -source alexnet/scripts/run_alexnet_n8_output_router.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_m4n8_result_scanner.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_n8_output_router.tcl
```

Run the N8 requant DPI regression and its only implementation experiment at
200 MHz:

```bash
vivado -mode batch -source alexnet/scripts/run_alexnet_n8_requant.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_n8_requant.tcl
```

Run the integrated scanner-requant-router regression and 200 MHz OOC
implementation:

```bash
vivado -mode batch \
  -source alexnet/scripts/run_alexnet_m4n8_n8_output_slice.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_m4n8_n8_output_slice.tcl
```

Run the complete M4xN8 base-datapath regression and its only OOC implementation
experiment at 200 MHz:

```bash
vivado -mode batch \
  -source alexnet/scripts/run_alexnet_m4n8_base_datapath.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_m4n8_base_datapath.tcl
```

Run the N8 streaming max-pool regression and its only OOC implementation
experiment at 200 MHz:

```bash
vivado -mode batch \
  -source alexnet/scripts/run_alexnet_n8_maxpool3x3.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_n8_maxpool3x3.tcl
```

Run the N8 activation-bank ownership/data regression and its only OOC
implementation experiment at 200 MHz:

```bash
vivado -mode batch \
  -source alexnet/scripts/run_alexnet_n8_activation_bank.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_n8_activation_bank.tcl
```

Run the N8 activation A/B ownership/overlap regression and its only OOC
implementation experiment at 200 MHz:

```bash
vivado -mode batch \
  -source alexnet/scripts/run_alexnet_n8_activation_pingpong.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_n8_activation_pingpong.tcl
```

Run the N8 dual-segment activation A/B regression and its only OOC
implementation experiment at 200 MHz:

```bash
vivado -mode batch \
  -source alexnet/scripts/run_alexnet_n8_activation_dual_segment_pingpong.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_n8_activation_dual_segment_pingpong.tcl
```

Run the N8 RS M4 window-feeder regression and its only OOC implementation
experiment at 200 MHz:

```bash
vivado -mode batch \
  -source alexnet/scripts/run_alexnet_n8_rs_m4_feeder.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_n8_rs_m4_feeder.tcl
```

Run the complete raster-to-INT8 M4xN8 datapath regression and its only OOC
implementation experiment at 200 MHz:

```bash
vivado -mode batch \
  -source alexnet/scripts/run_alexnet_m4n8_rs_datapath.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_m4n8_rs_datapath.tcl
```

Run the N8 weight-tile fill/replay regression and its only OOC implementation
experiment at 200 MHz:

```bash
vivado -mode batch \
  -source alexnet/scripts/run_alexnet_n8_weight_tile_bank.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_n8_weight_tile_bank.tcl
```

Run the resident-weight raster-to-INT8 regression and its only OOC
implementation experiment at 200 MHz:

```bash
vivado -mode batch \
  -source alexnet/scripts/run_alexnet_m4n8_rs_resident_weight_datapath.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_m4n8_rs_resident_weight_datapath.tcl
```

Run the N8 INT32 partial-sum chunk-accumulation regression and its only OOC
implementation experiment at 200 MHz:

```bash
vivado -mode batch \
  -source alexnet/scripts/run_alexnet_n8_int32_partial_sum_bank.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_n8_int32_partial_sum_bank.tcl
```

Run the accumulator-aware scanner/partial-sum/requant/router regression and its
only OOC implementation experiment at 200 MHz:

```bash
vivado -mode batch \
  -source alexnet/scripts/run_alexnet_m4n8_n8_accum_output_slice.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_m4n8_n8_accum_output_slice.tcl
```

Run the complete accumulator-aware M4xN8 base-datapath regression and its only
OOC implementation experiment at 200 MHz:

```bash
vivado -mode batch \
  -source alexnet/scripts/run_alexnet_m4n8_accum_base_datapath.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_m4n8_accum_base_datapath.tcl
```

Run the activation-buffered resident-weight dual-accumulator RS integration
regression and its only OOC implementation experiment at 200 MHz:

```bash
vivado -mode batch \
  -source alexnet/scripts/run_alexnet_m4n8_rs_activation_resident_weight_dual_accum_datapath.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_m4n8_rs_activation_resident_weight_dual_accum_datapath.tcl
```

Run the 128-bit AXI4-Stream to 64-bit N8 DMA-ingress regression and its only
OOC implementation experiment at 200 MHz:

```bash
vivado -mode batch -source alexnet/scripts/run_alexnet_n8_dma_ingress.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_n8_dma_ingress.tcl
```

Run the DMA-fed activation-buffered resident-weight dual-accumulator RS
regression and its only OOC implementation experiment at 200 MHz:

```bash
vivado -mode batch \
  -source alexnet/scripts/run_alexnet_m4n8_rs_dma_activation_resident_weight_dual_accum_datapath.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_m4n8_rs_dma_activation_resident_weight_dual_accum_datapath.tcl
```

Run the 64-bit N8 result-packet to 128-bit AXI4-Stream DMA-egress regression
and its only OOC implementation experiment at 200 MHz:

```bash
vivado -mode batch \
  -source alexnet/scripts/run_alexnet_n8_dma_result_egress.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_n8_dma_result_egress.tcl
```

Run the complete 128-bit MM2S-to-compute-to-128-bit S2MM DMA-loop regression
and its only OOC implementation experiment at 200 MHz:

```bash
vivado -mode batch \
  -source alexnet/scripts/run_alexnet_m4n8_rs_dma_io_activation_resident_weight_dual_accum_datapath.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_m4n8_rs_dma_io_activation_resident_weight_dual_accum_datapath.tcl
```

Run the registered DMA chunk-scheduler regression and its only OOC
implementation experiment at 200 MHz:

```bash
vivado -mode batch \
  -source alexnet/scripts/run_alexnet_dma_chunk_scheduler.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_dma_chunk_scheduler.tcl
```

Run the scheduler-controlled complete MM2S-to-compute-to-S2MM regression and
its only OOC implementation experiment at 200 MHz:

```bash
vivado -mode batch \
  -source alexnet/scripts/run_alexnet_m4n8_rs_dma_scheduled_io_datapath.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_m4n8_rs_dma_scheduled_io_datapath.tcl
```

Run the N8-activation to M4 fully-connected issuer regression and its only OOC
implementation experiment at 200 MHz:

```bash
vivado -mode batch \
  -source alexnet/scripts/run_alexnet_n8_fc_m4_issuer.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_n8_fc_m4_issuer.tcl
```

Run the resident-weight FC accumulator regression and its 200 MHz OOC
implementation. This verifies full K lengths on individual output tiles;
it does not yet schedule every output channel of a complete FC layer.

```sh
vivado -mode batch \
  -source alexnet/scripts/run_alexnet_m4n8_fc_resident_weight_accum_datapath.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_m4n8_fc_resident_weight_accum_datapath.tcl
```

Run the activation-buffered FC regression and its 200 MHz OOC implementation.
The fill stream uses full-byte masks and zero-padded K tails; the wrapper
reconstructs the issuer's per-word K masks when reading the resident tensor.

```sh
vivado -mode batch \
  -source alexnet/scripts/run_alexnet_m4n8_fc_activation_resident_weight_accum_datapath.tcl
vivado -mode batch \
  -source alexnet/scripts/synth_impl_alexnet_m4n8_fc_activation_resident_weight_accum_datapath.tcl
```

Run the FC DMA input/output regression and its 200 MHz OOC implementation.
This wrapper supplies AXIS-facing adapters; board AXI DMA IP, DDR addresses,
PS integration, and software are not instantiated here.

```sh
vivado -mode batch -source alexnet/scripts/run_alexnet_m4n8_fc_dma_io_datapath.tcl
vivado -mode batch -source alexnet/scripts/synth_impl_alexnet_m4n8_fc_dma_io_datapath.tcl
```

Enable `RUNTIME_SLICE_INDEX=1` on the FC DMA top to reuse one M4xN8 SA at
different logical output positions. Supply `cfg_slice_index=0..7` together
with the existing N64-aligned base, mask, destination, and requant settings.
Only `cfg_valid && cfg_ready` commits a new position. The router and the
automatic final-result DMA descriptor both retain that accepted position:
`egress_n_base = cfg_n64_tile_base + 8*cfg_slice_index`. A pending config
cannot change a partial-sum transaction or a stalled final result. Default
`RUNTIME_SLICE_INDEX=0` ignores the new input and preserves `SLICE_INDEX`.
Fixed-mode callers should tie the new port explicitly. The shared PE/SA and
all DMA adapter arithmetic/protocol RTL remain unchanged; non-FC wrapper
paths stay fixed-mode. This low-level wrapper does not itself schedule every
FC output channel; the layer wrapper below now supplies that controller.

The runtime router test covers all eight positions and the maximum 16-bit
N8 base. The runtime FC test reuses the full dense/DPI/error regression and
adds a complete N64 placement sweep plus the N=992 FC8 tail tile. OOC results
are kept separately under `reports/m4n8_fc_dma_runtime_placement/200mhz` so
the earlier fixed-mode measurement and its source hashes are preserved.

```sh
vivado -mode batch -source alexnet/scripts/run_alexnet_n8_output_router_runtime.tcl
vivado -mode batch -source alexnet/scripts/run_alexnet_m4n8_fc_dma_runtime_placement.tcl
vivado -mode batch -source alexnet/scripts/synth_impl_alexnet_m4n8_fc_dma_runtime_placement.tcl
```

## FC layer service boundary

`alexnet_m4n8_fc_layer_datapath` accepts one `job_valid && job_ready` command
with `job_layer_id=6/7/8`, `job_m_count=1..4`, and `job_tag`. One job processes
one complete layer for that M group, not the FC6-to-FC8 graph automatically.
It owns exactly one runtime-placement FC DMA datapath. N8 tiles are the outer
loop; K chunks are at most 968 words (10 chunks per FC6 tile, five per FC7/8
tile). FC8 has 125 N8 tiles and stops after N=992..999. FC6/7 output to the
activation-buffer destination with ReLU; FC8 outputs without ReLU to the
final-output destination. The frozen signed-27 post-bias requant range still
applies; the layer controller does not change the arithmetic contract.

Three external services must be connected:

| Service | Request/response contract |
|---|---|
| Parameters | `parameter_request_valid` requests the current `active_layer_id`, `active_job_tag`, and `active_n_base`. A matching `parameter_valid && parameter_ready` response completes that request. Supply eight bias/multiplier/shift records; metadata and frozen multiplier/shift ranges are checked before configuration. There is no separate parameter-request acknowledgement. |
| Input | Accept `read_request_valid && read_request_ready`, capturing the `active_*` coordinates and read-request fields. Destination 0 requests padded activation words `[K-block][M][K-lane]`; destination 2 requests weight words `[K][N-lane]` and has request M=0. Supply exactly the requested words through 128-bit MM2S AXIS, low 64-bit word first. Odd final beats use `TKEEP=00ff`, zero upper half, and final `TLAST`. Both descriptor masks are `FF`. |
| Results | Accept `result_request_valid && result_request_ready` before the final K chunk launches. Capture N base, active M, destination, byte count, and tag, and receive M N8 words through S2MM AXIS. Only after the receiving transfer really completes, return `result_complete_valid` with matching N base/tag and error status, holding it until `result_complete_ready`. |

These are logical coordinate requests, **not DDR addresses or an AXI DMA IP
driver**. The service must map the job/layer to real buffers, parameters, and
weights. Activation packing, pool5 flattening, DMA-IP completion observation,
and Linux/PS integration are not implemented here. The input activation bank
is consuming: the same input region is requested again for each N8 output
tile. No overlap/prefetch or shared full-layer activation cache is implied.

The transfer tag is `(job_tag + completed_chunks) mod 65536`; the output tile
and partial-sum context tag are `(job_tag + N_base/8) mod 65536`. Choose job
tags and reset/abort epochs so old service responses cannot be reused. Each
parameter payload is captured once. New requests and metadata remain stable
while stalled in normal operation. A fault may cancel an unaccepted request;
already owned data streams are not forcibly reset by the controller.

`layer_done` is a clean one-cycle success pulse only after all N8 tiles,
core/AXIS retirement, external result acknowledgements, and weight releases.
The counters reset on each accepted job. `completed_output_words` counts
64-bit N8 words, not individual class scores. Invalid layer/M commands pulse
`job_rejected` without acquiring child owners. Other errors latch `fault`
and pulse `layer_failed`; that failure pulse does not certify external buffer
release or DMA drain. Fault codes are 1=parameter record, 2=external service,
3=child failure/rejection, 4=result completion metadata/error, 5=lost nonfinal
accumulator ownership. Missing responses wait indefinitely. Quiesce/abort
external services, discard failed output, and reset controller and datapath
together before retrying. The final board must not acknowledge a result just
because its AXIS source has finished; actual receiving DMA completion matters.

The controller regression checks complete FC6 M4, FC7 M3, FC8 M1/M2 geometry
with a behavioral downstream model and negative ownership/parameter cases.
The integration regression uses the real FC DMA/SA path for a complete FC8
M1 layer with synthetic inputs, checking all 1,000 outputs against C++ dense
dot-product/requant references. It also checks malformed MM2S drain, M3 result
packing, bad result acknowledgement, backpressure, and reset recovery.
This is not trained-model accuracy or a camera demonstration.

```sh
vivado -mode batch -source alexnet/scripts/run_alexnet_fc_layer_controller.tcl
vivado -mode batch -source alexnet/scripts/run_alexnet_m4n8_fc_layer_datapath.tcl
vivado -mode batch -source alexnet/scripts/synth_impl_alexnet_fc_layer_controller.tcl
vivado -mode batch -source alexnet/scripts/synth_impl_alexnet_m4n8_fc_layer_datapath.tcl
```

Both OOC experiments run only at 200 MHz. Results and source hashes are in
`reports/fc_layer_controller/200mhz` and `reports/m4n8_fc_layer_datapath/200mhz`.
Full-board timing, full FC6/FC7 numerical integration, connection of the
standalone Pool5 flatten/root graph blocks, and camera/runtime remain
subsequent gates.

## Shared Conv/FC compute top

`alexnet_m4n8_shared_compute_top` is the first combined compute-level top.
The existing row-stationary Conv scheduler/DMA path and FC6/7/8 layer path
retain their own feeders, activation/weight storage, and service interfaces,
but both now drive exactly one common M4xN8 SA, INT32 partial-sum bank,
requantizer, and output router. The common bank is 4,096 N8 words so it covers
Conv1's complete 55x55/3,025-word raster, the 729-word Conv2 raster, and FC
M1..4. Conv1's 50,176-word RGB input bypasses the 1,024-word activation banks
through a dedicated ready/valid stream.
The packed PE, SA, issuer arithmetic, and requant RTL are unchanged.

The owner handshake admits either Conv or FC only at an idle boundary.
`owner_release_ready` remains low while a chunk, resident partial sum, output
stream, FC layer, or external FC result acknowledgement is outstanding. A
release does not reset the common compute state; the next owner therefore
depends on the verified drained boundary. Default `EXTERNAL_COMPUTE=0` keeps
all earlier standalone wrappers self-contained and backward-compatible.

The combined regression runs the existing two-chunk 27x27 Conv numerical/error
suite, releases the drained Conv owner, then runs a complete FC8 M1 layer
without an intervening reset. All 1,000 FC8 outputs are checked against the
C++ dot-product/requant reference. It also retains the existing malformed-DMA,
bad-result-acknowledgement, stalls, and recovery cases, while attempting early
owner release throughout active computation.

```sh
vivado -mode batch -source alexnet/scripts/run_alexnet_shared_compute.tcl
vivado -mode batch -source alexnet/scripts/synth_impl_alexnet_m4n8_shared_compute_top.tcl
```

Both commands use the single 200 MHz target. This top is still a logical AXIS
service boundary, not the KV260 AXI-MM/PS board top: the standalone graph and
flatten blocks are not yet connected, and pooling, physical DDR address
generation, AXI-Lite registers, Linux runtime, and USB camera integration
remain.

The routed OOC result is 9,063 CLB LUT, 7,721 FF, 42 RAMB36E2, and 24
DSP48E2 with WNS/WHS of +0.017/+0.046 ns. Synthesis asserts that exactly one
`alexnet_sa_m4n8` and 24 DSP48E2 cells exist. Reports and hashes are under
`reports/m4n8_shared_compute_top/200mhz`.

## Logical graph and Pool5-to-FC6 boundary

The standalone `alexnet_graph_controller` fixes the complete layer order and
all Conv/pool geometry, then performs one drained ownership handoff from Conv
to FC. The standalone `alexnet_pool5_fc6_flatten_reader` maps Pool5 tile-major
addresses into all ten FC6 K chunks without consuming DSP or BRAM. Their
regressions cover all eight jobs and all 9,216 flattened scalars respectively.
The graph regression also checks that mismatched completion metadata raises a
stable protocol fault.

```sh
vivado -mode batch -source alexnet/scripts/run_alexnet_graph_controller.tcl
vivado -mode batch -source alexnet/scripts/run_alexnet_pool5_fc6_flatten_reader.tcl
vivado -mode batch -source alexnet/scripts/synth_impl_alexnet_graph_controller.tcl
vivado -mode batch -source alexnet/scripts/synth_impl_alexnet_pool5_fc6_flatten_reader.tcl
```

Both implementations use only the 200 MHz target. The graph controller routes
at 94 LUT/38 FF and WNS +2.051 ns. The flatten reader routes at 311 LUT/291 FF
and WNS +0.843 ns, with zero BRAM/DSP and zero DRC violations. They remain
logical service boundaries until pool storage and the physical memory service
are connected.

## Graph-connected compute top

`alexnet_conv_layer_controller` now expands Conv1 through Conv5 into the
complete N8-major/K-chunk-minor schedule: 144 output N8 tiles and 3,912
commands per image. It validates the fixed graph geometry, acquires parameters
per output tile, holds accumulator context across nonfinal input chunks, and
waits for the external result/pool commit before completing a layer. Its full
schedule regression also holds a fault on mismatched command completion
metadata.

`alexnet_graph_compute_orchestrator` connects that controller to the graph
root, then hands the same compute owner to the existing FC6/7/8 controller.
The integration regression executes all 3,912 abstract Conv command
completions, five layer commits, three FC jobs, and exactly two owner
acquisitions/releases. `alexnet_m4n8_graph_compute_top` wraps the orchestrator
around the real shared SA/DMA/FC hierarchy. It elaborates as one hierarchy and
routes at 200 MHz with 8,878 LUT, 7,355 FF, 42 RAMB36E2, and 24 DSP48E2.
WNS/WHS are +0.008/+0.031 ns, and all 16,124 routable nets are connected.

```sh
vivado -mode batch -source alexnet/scripts/run_alexnet_conv_layer_controller.tcl
vivado -mode batch -source alexnet/scripts/run_alexnet_graph_compute_orchestrator.tcl
vivado -mode batch -source alexnet/scripts/synth_impl_alexnet_m4n8_graph_compute_top.tcl
```

This graph-compute-only top still exposes logical data services. Its
3,912-command regression verifies control metadata and ordering rather than
full trained-model graph numerics. The next section describes the newer top
that connects pooling and FC6 flatten injection around it.

## Connected data service and graph-data top

`alexnet_conv_fc_data_service` connects the real Conv result stream through
one reused pool/bypass engine and a common storage AXIS port. Pool5 is also
written to a local 512x144 cache; its 128-to-144 gearbox makes the exact
73,728-bit payload fit two RAMB36E2. The same cache feeds
`alexnet_pool5_fc6_flatten_reader`, so FC6 activation requests are generated
internally while weights and FC7/8 payloads continue through external MM2S.

The component regressions cover every Conv layer contract and a numerical
Conv5-to-Pool5-to-FC6 flow:

```sh
vivado -mode batch -source alexnet/scripts/run_alexnet_conv_result_pool_service.tcl
vivado -mode batch -source alexnet/scripts/run_alexnet_pool5_n8_store.tcl
vivado -mode batch -source alexnet/scripts/run_alexnet_fc6_flatten_injector.tcl
vivado -mode batch -source alexnet/scripts/run_alexnet_conv_fc_data_service.tcl
vivado -mode batch -source alexnet/scripts/synth_impl_alexnet_conv_fc_data_service.tcl
```

The data-service OOC result at 200 MHz is 2,049 LUT, 1,546 FF, exactly three
RAMB36E2, zero DSP, WNS +0.348 ns, and WHS +0.055 ns. The pool consumes one
RAMB36E2 and the Pool5 cache consumes two.

`alexnet_ddr_address_planner` converts fixed AlexNet layer coordinates and
programmable base addresses into physical descriptors. It protects Conv1's
direct stream and FC6's internal flatten path, covers 61,090,496 weight bytes
and 165,504 parameter bytes, and uses constant shift/add address functions so
no DSP is inferred. Its 21,893-descriptor regression and 200 MHz OOC run are:

```sh
vivado -mode batch -source alexnet/scripts/run_alexnet_ddr_address_planner.tcl
vivado -mode batch -source alexnet/scripts/synth_impl_alexnet_ddr_address_planner.tcl
```

The planner routes with 921 LUT, 344 FF, zero BRAM/DSP, WNS +0.372 ns, and
WHS +0.055 ns.

`alexnet_m4n8_graph_data_top` joins the graph-compute hierarchy and data
service. The Conv result sink is armed before the first command, and its
completion is retained if it coincides with the last command. Conv and FC
results share one external storage AXIS port; `storage_owner_fc` identifies
the active meaning. Synthesis asserts one SA, one pool, one Pool5 cache, one
flatten reader, 24 DSP48E2, and 45 RAMB36E2.

```sh
vivado -mode batch -source alexnet/scripts/synth_impl_alexnet_m4n8_graph_data_top.tcl
```

The routed 200 MHz hierarchy is 10,938 CLB LUT, 8,899 FF, 45 RAMB36E2, and
24 DSP48E2 with WNS/WHS +0.098/+0.046 ns and all 19,330 routable nets
connected. This graph-data-only result is retained as an intermediate
measurement; the following top supersedes its logical DMA boundary.

## Physical DMA and software-controlled accelerator top

`alexnet_graph_dma_descriptor_bridge` arbitrates six logical request classes
through the DDR planner and presents one stable physical command to the
existing `axi_dma_simple_master`. Activation/weight streams remain on the graph
path, while `alexnet_graph_dma_read_router` diverts parameter transfers into
`alexnet_parameter_record_loader`. That loader consumes eight frozen
little-endian `<iiBB6x>` records and delivers one complete N8 parameter tile.

Post-pool Conv traffic uses `alexnet_conv_storage_dma_scheduler`; it converts
the five aggregate layer stores into 144 physical N8-tile S2MM transfers. This
is required because Conv1, Conv2, and Conv5 raw output sizes differ from their
stored pooled sizes. Its regression checks all 24,560 stored N8 words and every
descriptor/completion boundary.

`alexnet_m4n8_graph_dma_top` integrates graph compute, pooling/cache/flatten,
all descriptor owners, the address planner, parameter loading, stream routing,
post-pool storage scheduling, and one physical AXI DMA register master. The
AXI DMA IP must enable DRE on MM2S and S2MM; FC8 legally creates 8-byte-aligned
single-word descriptors. The routed 200 MHz result is 12,266 CLB LUT, 9,946 FF,
45 RAMB36E2, and 24 DSP48E2 with WNS/WHS +0.088/+0.046 ns and all 21,883
routable nets connected.

`alexnet_axi_lite_regs` provides the PS control plane. Software writes shadow
DDR bases, timeout, and job tag, then submits into a one-entry pending mailbox.
The pending and active snapshots remain isolated from later writes. Completion,
failure, fault, and rejected-submit status are sticky/W1C and may drive IRQ.
The complete register ABI is in `../CONTROL_REGISTERS.md`.

`alexnet_m4n8_accelerator_top` is the reusable Vivado-IP boundary. It adds the
32-bit control slave, 64-bit preprocessed-camera stream, 128-bit AXI DMA
payload streams, AXI DMA control master, and interrupt around the complete
graph-DMA hierarchy. Its register regression covers independent AW/W ordering,
read/write response backpressure, byte strobes, job snapshotting, queue and
configuration rejection, sticky status, and interrupt clearing:

```sh
vivado -mode batch -source alexnet/scripts/run_alexnet_parameter_record_loader.tcl
vivado -mode batch -source alexnet/scripts/run_alexnet_graph_dma_read_router.tcl
vivado -mode batch -source alexnet/scripts/run_alexnet_conv_storage_dma_scheduler.tcl
vivado -mode batch -source alexnet/scripts/run_alexnet_graph_dma_descriptor_bridge.tcl
vivado -mode batch -source alexnet/scripts/run_alexnet_axi_dma_simple_master_alignment.tcl
vivado -mode batch -source alexnet/scripts/run_alexnet_axi_lite_regs.tcl
vivado -mode batch -source alexnet/scripts/synth_impl_alexnet_m4n8_accelerator_top.tcl
```

The complete control-plus-accelerator IP routes at the sole 200 MHz target with
12,730 CLB LUT, 11,503 FF, exactly 45 RAMB36E2, and exactly 24 DSP48E2.
WNS/WHS are +0.021/+0.036 ns, TNS/THS are zero, and all 23,821 routable nets
are connected.

## KV260 board top and bitstream

`stages/01_kv260_m4n8` packages the accelerator and the camera RGBX adapter as
Vivado IP, then builds `system_wrapper` for the KV260/K26. The stock PS PL0
clock is 99.999001 MHz; one MMCM generates the 199.998002 MHz fabric domain
that connects a DRE-enabled 128-bit main MM2S/S2MM AXI DMA, a
PS-owned 64-bit camera MM2S AXI DMA, the shared HP0 DDR interconnect, and five
interrupt sources. The camera adapter accepts one eight-byte DDR word per
preprocessed `224x224` RGB pixel and produces one three-lane N8 Conv1 word.

The complete routed board design uses 21,089 CLB LUT, 22,696 FF, 52 block RAM
tiles, and 24 DSP48E2. At the sole 200 MHz target it has WNS/WHS
+0.026/+0.010 ns, zero TNS/THS, zero routing errors, and zero DRC errors or
critical warnings. The generated `.bit` and bitstream-bearing `.xsa`, build
commands, address/interrupt map, and exact camera buffer ABI are documented in
`../stages/01_kv260_m4n8/README.md`.

This closes hardware construction through bitstream generation. It does not
yet claim physical board programming or functional inference. Trained weights
and data must be packaged, and the Linux V4L2/OpenCV capture, preprocessing,
DMA/control, top-k decoding, and Korean terminal-label runtime remain the next
milestone.
