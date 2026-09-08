# AlexNet RTL status — 2026-09-07

## Current decision

- Experiments use one clock only: **200 MHz**.
- PE resource optimization is deferred.
- The bring-up SA is logical **M4xN8**, implemented as a physical **2x8**
  packed-PE grid (16 DSP48E2).
- N remains fixed at 8. After the base datapath is integrated and PE resources
  are revisited, the tile expands once in M to logical **M8xN8** (physical
  4x8) without changing its N8-facing boundary.

`PRE_RTL_SIGNOFF.md` remains the historical pre-RTL signoff. The post-measurement
override is recorded under `rtl_bringup_revision` in `alexnet_contract.yaml`.

## Board demonstration target

The release demonstration is one complete camera-to-label path. A USB camera
is captured by KV260 Linux through V4L2/OpenCV; the PS performs resize,
center-crop, RGB normalization, INT8 quantization, and DMA packing. The PL runs
the complete AlexNet graph and returns final logits or top-k records. The PS
maps the winning ImageNet index to both a detailed class and an optional Korean
coarse category, so a terminal result can read `결과: 강아지 (golden
retriever)`. Live capture, full-layer/FC scheduling, multi-layer root control,
and the runtime are release requirements. Full Conv/FC graph control is now
connected to the real shared compute hierarchy, but its 3,912-command
regression uses abstract payload/completion services rather than a trained
end-to-end numerical image. The scheduler-owned MM2S/compute/S2MM boundary is
also numerically verified for the measured two-chunk conv2 path. The FC issuer
is connected to resident weights and the accumulator datapath, with full
K=9216/4096 reductions verified on individual M/N output tiles. One-bank FC
activation storage/read ownership is verified, as is the FC 128-bit
MM2S/S2MM-facing adapter loop. Runtime N8 output placement is connected through
the FC path and verified with one SA. An FC6/7/8 layer controller performs the
complete N8/K-chunk sweep, and a full FC8 synthetic numerical run is verified
through the real FC DMA datapath. FC6/7 full-layer controller geometry is
verified with a behavioral downstream model; their all-channel numerical
integration is not claimed by that test. The logical Pool1/2/5 bypass/pooling
stream, two-BRAM Pool5 cache, and automatic Pool5-to-FC6 flatten injection are
now connected to the graph top. Physical DDR descriptor arbitration, parameter
record loading, post-pool tile storage scheduling, the AXI DMA control master,
and the PS-facing AXI-Lite register bank are also connected in the accelerator
IP top. The KV260 block design now connects ZynqMP PS, shared DDR, the main and
camera AXI DMA IPs, the 199.998002 MHz MMCM fabric clock/reset domain, and all
five IRQ sources;
its routed `system_wrapper` has generated a timing-clean bitstream and XSA.
The measured Conv and FC paths share one M4xN8 compute/output block and have
passed a clean Conv-to-FC8 ownership handoff without resetting that block.
The official torchvision checkpoint has now also been converted into frozen
contract-matching INT8 files and packed into the exact RTL weight/parameter DDR
order. The 61,090,496-byte weight image and 165,504-byte parameter image retain
separate aligned bases. A host-tested Linux driver/runtime now owns the
61,767,680-byte page-aligned coherent DDR allocation (61,766,656 bytes used), checks the near-100 MHz PS PL0 input and
fixed 199.998002 MHz fabric-clock contract,
preprocesses saved images or V4L2/OpenCV frames, controls the camera DMA, and
decodes the 1,000 signed INT8 FC8 outputs into top-k terminal labels. The
timing-clean image and driver are now loaded on the physical KV260; coherent
DMA mapping, RTL ID/build word, and 200 MHz clock inspection pass. Loading the
model into board DDR and trained camera-to-terminal inference remain open.

## Implemented RTL

### Packed PE

`rtl/packed_mac/alexnet_packed_pe.sv` implements fixed GEMM WP487
split-every-cycle multiplication, signed-27 accumulation, INT32 ABI extension,
standalone aligned clear, reduce-last capture, and a one-entry ready/valid
holding register.

### M4xN8 base tile

`rtl/sa/alexnet_sa_m4n8.sv` owns:

- activation row skew and weight column skew;
- horizontal activation/control hops and vertical weight hops;
- one shared `(row skew + four DSP cycles)` control tap per physical row;
- M-tail masking, including a fully inactive second physical row;
- 16 independent packed-PE result holdings and ready signals.

### M4xN8 result scanner

`rtl/result/alexnet_m4n8_result_scanner.sv` converts the packed holding bank to
one N8 accumulator beat per logical M coordinate. It supports M=1..4, contiguous
N-tail masks, staggered PE completion, ready/valid stalls, and releases a
physical PE row only after its final active packed lane transfers.

### N8 output router

`rtl/result/alexnet_n8_output_router.sv` is one of the independent N8 router
slices. Its 64-entry packet FIFO stores 64-bit INT8 data plus M and tile tags.
Destination, N-base, and N-tail mask stay in slice-local configuration registers
because the descriptor cannot change until the FIFO empties; duplicating those
fields in every entry is unnecessary. It supports full-FIFO same-cycle pop/push,
descriptor changes only at an empty boundary, and masked-lane zeroing. An
opt-in runtime slice selector is also captured with the descriptor; the
default fixed-slice mode is preserved.

### N8 requantization

`rtl/postprocess/alexnet_n8_requant.sv` is the five-stage N-stationary block
between the scanner and one router slice. Eight lane-local parameter records
remain fixed while data is in flight. The pipeline performs bias addition in
the DSP pre-adder, exact signed 27x18 multiplication, half-away-from-zero
rounding over the frozen shift range 23..32, optional lane-local ReLU, and
signed INT8 saturation. It accepts one N8 beat per cycle when unstalled, freezes
all data and coordinate stages under output backpressure, and only changes
parameters after the complete pipeline drains.

### Integrated M4xN8 N8 output slice

`rtl/integration/alexnet_m4n8_n8_output_slice.sv` connects the scanner,
five-stage requant pipeline, and 64-entry router FIFO without changing the PE
or SA. One top-level configuration handshake atomically installs the eight
requant parameter records and router descriptor only when all three blocks are
idle. A pending change immediately blocks new tiles while accepted scanner,
pipeline, and FIFO work continues to drain.

### Complete M4xN8 base datapath

`rtl/integration/alexnet_m4n8_base_datapath.sv` connects the unchanged M4xN8
SA and packed PEs to the integrated output slice. The wrapper atomically pairs
one standalone SA clear with the scanner tile descriptor, derives the two
physical-row lane masks from M=1..4, accepts a backpressured K stream through
`issue_valid/ready/last`, and releases the compute tile only after every active
PE holding has transferred. A pending configuration cannot start another tile
but does not deadlock an accepted K reduction or the draining output path.

### N8 streaming max-pool slice

`rtl/pool/alexnet_n8_maxpool3x3.sv` implements one independent N8
3x3/stride-2/padding-0 stream for the router's `pool3x3` destination. It accepts
runtime frame dimensions up to width 55, preserves lane mask, N-base, output
coordinates, and frame tag, and freezes cleanly under output backpressure.
Instead of storing two complete preceding rows, one 55x64-bit line memory
alternates between an even row and the lane-wise maximum of that row with the
following odd row. The next even row completes the vertical three-tap maximum,
then two registers complete the horizontal three-tap maximum. This maps the
slice to one BRAM36 while retaining one input pixel per cycle when unstalled.

### N8 activation-memory bank

`rtl/memory/alexnet_n8_activation_bank.sv` is the reusable 512x64-bit physical
bank unit for one N8 slice. Direct router packets and pooled raster packets are
normalized to one sequential write stream. The bank enforces
`EMPTY -> WRITING -> READY -> READING -> EMPTY`, requires `write_last` and the
descriptor word count to agree, zeroes invalid N-tail lanes before storage, and
returns index, last, lane mask, and tensor tag on a backpressured raster read.
A single instance never reads and writes simultaneously; independent A/B
instances provide the intended cross-bank overlap. Larger layer boundaries
cascade this measured 4 KiB unit rather than widening the 64-bit N8 port.

### N8 activation A/B ping-pong boundary

`rtl/memory/alexnet_n8_activation_pingpong.sv` composes two unchanged
512x64-bit activation banks behind one ordered owner. Each accepted fill
descriptor fixes either the direct-router or pooled-raster source for the
complete tensor. Only that source receives ready, and malformed masks or last
markers remain backpressured without reaching either child bank.

Completed tensors enter a two-entry bank-ID queue. A consumer may start only
from the queue head and only when its requested tensor tag matches, so READY
order cannot be bypassed. The other physical bank may accept and store the next
tensor during a backpressured read; a single bank still follows its original
exclusive `EMPTY -> WRITING -> READY -> READING -> EMPTY` ownership. This
two-bank unit holds two independent rasters of at most 512 N8 words each.

### N8 dual-segment activation A/B ping-pong boundary

`rtl/memory/alexnet_n8_activation_dual_segment_pingpong.sv` composes two
unchanged activation ping-pong units. Logical activation sets A and B each own
two physical 512x64-bit segments, for 1,024 N8 words per set and four RAMB36E2
payload banks in total. An accepted 513..1,024-word descriptor is installed in
both segment owners atomically; the global stream splits at word 512, so the
pool1/conv2 27x27 raster is stored as 512 plus 217 words.

The pair owns one ordered two-entry READY queue and requires the same bank and
tensor tag at both child heads. A read starts in both segments atomically,
drains segment 0 first, then reconstructs global indices while draining the
already-prefetched segment 1. Source ownership, lane-mask checking, final-word
checking, same-bank exclusion, and cross-set fill/read overlap remain enforced
by the measured child ping-pong units.

### N8 RS M4 window feeder

`rtl/feeder/alexnet_n8_rs_m4_feeder.sv` consumes one raster-ordered N8 input-
channel word stream and produces row-local M4 activation groups directly in
the frozen `[kernel_y][kernel_x][input_channel]` order required by the SA. One
descriptor-controlled datapath supports K11/s4/p2, K5/s1/p2, and K3/s1/p1;
the final group of every output row carries an M1..M3 tail when needed. Source
bubbles, output backpressure, padding insertion, K index, clear/last control,
coordinates, and frame tags all remain aligned.

The feeder never stores a complete frame. It walks a virtual padded raster and
retains at most 11 rows by 228 words. The 2,508 live words are explicitly split
into five 512x64-bit banks so Vivado maps exactly five RAMB36E2 primitives
instead of expanding the irregular depth into a larger cascade. Scanning
pauses while a window group is read, guaranteeing that a live ring row cannot
be overwritten under source or SA-side stalls.

### RS tile issue controller and complete raster datapath

`rtl/control/alexnet_m4n8_rs_issue_controller.sv` accepts each feeder M group,
requests one matching external N8 weight context, starts exactly one base-tile
descriptor, and then transfers activation and weight K tokens atomically. It
checks K index and reduction-last alignment, preserves the feeder's M tail and
coordinates, and does not admit the next group until the current compute tile
has completed.

`rtl/integration/alexnet_m4n8_rs_datapath.sv` connects the five-BRAM raster
feeder, issue controller, and complete M4xN8 base datapath without changing the
PE or SA. The current boundary deliberately leaves N8 weights external as a
context followed by a backpressured K stream. Configuration and a new frame are
accepted only at a fully drained boundary, while `frame_done` waits for both
compute completion and feeder retirement; output packets may then drain
independently until `pipeline_idle`.

### N8 weight tile bank and replay streamer

`rtl/memory/alexnet_n8_weight_tile_bank.sv` stores one resident 968x64-bit N8
weight tile, covering the maximum K11 by eight-input-channel feeder chunk. Its
ownership is `EMPTY -> WRITING -> READY <-> REPLAYING`, followed by explicit
release back to `EMPTY`. Fill masks invalid N-tail lanes before storage.

A replay request is accepted only when K count, N lane mask, and context tag
all match the resident descriptor. The streamer generates K=0..K-1 and last
internally, freezes its elastic BRAM read path under backpressure, and returns
to `READY` after the final transfer without erasing the tile. The same weights
can therefore rewind for each spatial M group without another fill.

### Resident-weight complete RS datapath

`rtl/integration/alexnet_m4n8_rs_resident_weight_datapath.sv` connects the
measured weight tile bank to the complete RS datapath without changing the PE,
SA, or base-tile boundary. Software fills one N8 weight tile once, then submits
a frame descriptor carrying the same K count, N mask, and weight-context tag.
Each spatial M group starts an internal replay, so all groups reuse the resident
weights without an external per-K weight stream.

The wrapper accepts a frame only while the bank is `READY` and its descriptor
matches the resident context. Fill, release, and context replacement remain
blocked for the complete active frame; frame retirement additionally waits for
the final replay to return the bank to `READY`. This boundary is deliberately
limited to one input-channel chunk of at most eight channels. INT32 partial-sum
continuation across multiple chunks is not integrated into this wrapper yet.

### N8 INT32 partial-sum bank

`rtl/memory/alexnet_n8_int32_partial_sum_bank.sv` is one 512x256-bit physical
bank unit holding eight signed INT32 accumulators per spatial word. Its
ownership is `EMPTY -> INGEST_FIRST -> READY -> INGEST_ACCUM -> READY ... ->
EMITTING -> EMPTY`. The first input-channel chunk replaces storage, middle and
final chunks use a one-word-per-cycle BRAM read-add-write pipeline, and no data
is exposed to requantization until the final chunk is complete.

The descriptor binds word count, contiguous N-tail mask, context tag, and
strictly increasing chunk index. Each input beat additionally carries its
sequential spatial-word index and last marker. A mismatched or stale descriptor
and an out-of-order word both remain backpressured and latch an error, so they
cannot corrupt or release a final result. One unit stores 512 spatial N8 words,
or 16 KiB; larger raster ownership is formed by cascading identical units.

### Accumulator-aware M4xN8 N8 output slice

`rtl/integration/alexnet_m4n8_n8_accum_output_slice.sv` inserts the measured
partial-sum bank between the unchanged scanner and requant pipeline, followed
by the existing router. A chunk descriptor binds word count, output width, N
mask, accumulation context, base tile tag, chunk index, and first/final state.
Each accepted chunk covers one complete raster segment beginning at x=0.

The ingress sequencer converts row-local scanner M coordinates and tile tags to
strictly sequential bank word indices. Only a final chunk starts bank emission;
the egress sequencer reconstructs row-local M and tile tags from the stored
output width and base tag, so the 512x256-bit BRAM payload contains only eight
INT32 partial sums. Non-final chunks cannot reach requantization or the router.
One instance covers the complete 13x13 rasters of conv3 through conv5, including
conv4's maximum 48 input-channel chunks. The earlier non-accumulating output
slice remains available for single-chunk and isolated-block verification.

### Accumulator-aware complete M4xN8 base datapath

`rtl/integration/alexnet_m4n8_accum_base_datapath.sv` connects the unchanged
M4xN8 SA and packed PEs to the accumulator-aware output slice. Each spatial
tile start is one standalone SA clear plus one scanner descriptor handshake;
the wrapper derives the two physical-row M masks and accepts a backpressured K
stream exactly as the original base datapath does. The chunk descriptor now
owns the complete raster transaction around those compute tiles.

A non-final chunk releases compute after its final scanner word reaches the
partial-sum bank while bank ownership remains resident for the next channel
chunk. A final chunk additionally drains the accumulated raster through
requantization and the router. A pending configuration wins over a new first
chunk only at a fully drained boundary, but cannot block an owned transaction's
remaining tiles or continuation chunks. Only the accepted eight-bit lane mask
is shadowed in the wrapper; requant and router retain their existing local
configuration registers. The original non-accumulating base datapath remains
unchanged for comparison.

### Resident-weight accumulator-aware complete RS datapath

`rtl/integration/alexnet_m4n8_rs_resident_weight_accum_datapath.sv` connects
the unchanged five-BRAM RS feeder, issue controller, resident weight bank, and
accumulator-aware base datapath. One atomic chunk handshake starts both the
raster feeder and partial-sum descriptor only when the resident K count, N
mask, and weight-context tag match. The resident tile then rewinds once for
each spatial M group while the unchanged M4xN8 SA consumes the K stream.

Chunk retirement waits for feeder completion, controller/SA retirement,
partial-sum `chunk_done`, and the weight bank's return to `READY`. At that
boundary software may release and refill only the weight bank even though the
partial-sum transaction remains resident. A final chunk drains the accumulated
raster through requantization and the router. A configuration held pending
during the transaction cannot block continuation chunks, and weight owner
changes remain forbidden while any chunk is active. The earlier single-chunk
resident-weight and external-weight RS wrappers remain unchanged.

### Two-segment N8 INT32 partial-sum bank

`rtl/memory/alexnet_n8_int32_partial_sum_bank_pair.sv` composes two unchanged
512x256-bit partial-sum banks into one 513..1024-word raster owner. One atomic
descriptor is presented to both children. Sequential ingress words 0..511 go
to segment 0 and the remaining words are rebased into segment 1; the global
word count, chunk index, context, and N mask remain pair-owned.

The pair does not expose a final result until both children have completed the
final chunk. It then drains segment 0 followed by segment 1 and restores the
global sequential index, so the downstream requant/router boundary observes
one uninterrupted raster. Conv2's 27x27 output uses the fixed 512/217 split.
The original one-bank module and its protocol remain unchanged.

### Dual-accumulator resident-weight complete RS datapath

`rtl/integration/alexnet_m4n8_n8_dual_accum_output_slice.sv`,
`rtl/integration/alexnet_m4n8_dual_accum_base_datapath.sv`, and
`rtl/integration/alexnet_m4n8_rs_resident_weight_dual_accum_datapath.sv`
extend the measured resident-weight accumulator path only at the partial-sum
capacity boundary. The logical M4xN8 SA, packed PEs, five-BRAM feeder, issue
controller, resident weight bank, requantizer, and router are unchanged.

The integrated path accepts a complete 27x27 raster per input-channel chunk,
accumulates twelve conv2 chunks with K=200 each, and releases 729 ordered final
packets only after the last chunk. Configuration-pending, context-rejection,
weight replacement, and chunk-retirement rules are the same as the one-bank
resident path.

### Activation-buffered dual-accumulator resident-weight RS datapath

`rtl/integration/alexnet_m4n8_rs_activation_resident_weight_dual_accum_datapath.sv`
connects the unchanged dual-segment activation A/B owner to the unchanged
resident-weight dual-accumulator RS datapath. The wrapper mirrors each
completed activation tensor's word count, lane mask, tag, and bank in a
two-entry ordered metadata queue, then forwards the selected 64-bit N8 raster
directly into the existing RS feeder.

One registered command slot captures a chunk descriptor before validation,
breaking the external descriptor-to-feeder start path. A valid command starts
the activation read and compute chunk atomically only after the READY tensor
tag, geometry, lane mask, and resident-weight context all match. A rejected
command pulses `chunk_rejected` without consuming either activation or weight
ownership. Resident-weight fill/release and configuration changes are blocked
while a command is pending or a chunk is active; the activation child may
still fill the opposite A/B set during the active read. Top-level completion
waits for both activation-read and RS-chunk retirement. The PE, SA, feeder,
activation children, weight bank, accumulator, requantizer, and router are
unchanged.

### N8 DMA ingress

`rtl/dma/alexnet_n8_dma_ingress.sv` converts one 128-bit AXI4-Stream MM2S
transfer into the existing 64-bit N8 activation or resident-weight fill ports.
A one-entry descriptor register validates destination, word/byte count,
contiguous lane mask, and per-destination capacity before asserting either
owner's fill descriptor. A valid request may wait for a busy owner; an invalid
request pulses `descriptor_rejected` without consuming any owner.

One registered AXIS beat is emitted low 64-bit word first and naturally
backpressures the DMA while either internal word is stalled. Full beats use
`TKEEP=16'hffff`; an odd final N8 word uses `16'h00ff`. `TLAST/TKEEP`
mismatches latch `stream_error` while the descriptor-counted transfer drains
deterministically, allowing the future scheduler to report the fault and
forbid compute. Direct activation, pooled activation, and resident-weight
destinations share the adapter, while all storage children remain unchanged.

### N8 DMA result egress

`rtl/dma/alexnet_n8_dma_result_egress.sv` converts the existing ordered
64-bit N8 result packets into a 128-bit AXI4-Stream S2MM payload. A registered
descriptor validates nonzero word count, maximum capacity, exact byte count,
destination, eight-channel N-base alignment, and contiguous lane mask before
accepting any router packet. Invalid descriptors pulse `descriptor_rejected`
without consuming payload.

The two-word packer places the older packet in the low 64 bits and can accept
the next packet while a full non-final beat is transferred. Full beats use
`TKEEP=16'hffff`; an odd final word uses `16'h00ff`, a zero high half, and
`TLAST`. Static destination/slice/N-base/lane metadata, masked-zero bytes, and
monotonic M/tile-tag order are checked on every packet. A mismatch latches
`metadata_error` while the descriptor-counted transfer drains, and completion
retains the first and last tile tags for software correlation. The output
router and compute datapath are unchanged.

### DMA-fed activation-buffered dual-accumulator resident-weight RS datapath

`rtl/integration/alexnet_m4n8_rs_dma_activation_resident_weight_dual_accum_datapath.sv`
connects the 128-bit DMA ingress directly to the measured activation and
resident-weight fill owners of the activation-buffered RS datapath. A DMA
activation descriptor therefore commits exactly one direct or pooled READY
tensor, and a DMA weight descriptor commits exactly one resident tile; the
existing registered chunk validation then matches both owner tags before an
atomic activation-read/compute launch.

The wrapper exposes one composite protocol status. A sticky DMA stream error
forbids `chunk_valid/chunk_ready` handshakes until software clears the error,
while an invalid DMA descriptor is rejected before either storage owner sees
it. `pipeline_idle` additionally waits for the DMA adapter to become idle. The
DMA, activation, weight, feeder, PE, SA, accumulator, requantizer, and router
children are all unchanged; this step only closes the dispatch wiring and the
error-to-launch interlock.

### Full DMA-loop activation-buffered dual-accumulator resident-weight RS datapath

`rtl/integration/alexnet_m4n8_rs_dma_io_activation_resident_weight_dual_accum_datapath.sv`
connects the measured DMA-fed compute wrapper's router output directly to the
unchanged N8 DMA result egress. A valid S2MM descriptor must be active before
the router can consume its first result packet, so output metadata and transfer
ownership are established before any payload leaves the compute boundary.

`pipeline_idle` now requires both the compute/input-DMA child and result DMA to
be idle. The top-level protocol status combines input/compute and output DMA
errors. A sticky result metadata error lets its already-owned transfer drain
deterministically but interlocks every later chunk handshake until software
clears it. The input DMA, activation and weight owners, feeder, PE, SA,
accumulator, requantizer, router, and result DMA children are unchanged.

### Registered DMA chunk scheduler

`rtl/control/alexnet_dma_chunk_scheduler.sv` captures one complete software
command and holds every downstream request stable until its ready/valid
handshake. It sequences activation MM2S, optional stale resident-weight
release, weight MM2S, final-only result S2MM setup, atomic chunk launch,
post-chunk weight release, and command completion. A final chunk cannot launch
until the result adapter reports an active owned transfer.

For Conv1, a registered streaming flag replaces activation MM2S with the
direct ready/valid raster input. Cross-field validation requires both
activation word and byte counts to be zero in that mode; the remaining weight,
result-arm, chunk, and retirement ordering is unchanged.

The scheduler accepts a command only while the datapath is configured, both DMA
directions are idle, and the compute side is at a quiescent command boundary.
A non-final command retires at that boundary while the accumulator transaction
intentionally remains open for the next chunk. A final command waits until the
result transfer completes and the full datapath reports idle. Cross-field
validation occurs after command registration, and a bad relationship is
rejected before any child request. Downstream input or result descriptor
rejection, chunk rejection, or the composite protocol status enters a stable
fault phase. Error clear is held off while owned work is busy; after drain,
both DMA error domains are cleared together and the scheduler waits for the
composite error to fall before accepting a restart. No PE, SA, DMA, storage, or
compute child RTL changes in this step.

### Scheduler-controlled full DMA-loop datapath

`rtl/integration/alexnet_m4n8_rs_dma_scheduled_io_datapath.sv` places the
registered scheduler around the unchanged full MM2S/compute/S2MM datapath. The
scheduler is the sole owner of activation and weight input descriptors, final
result descriptors, resident-weight release, and chunk launch. The external
boundary therefore exposes one software command, configuration, both 128-bit
AXI4-Stream directions, scheduler status, and detailed child status, with no
parallel manual-control path.

The wrapper distinguishes a quiescent command boundary from full pipeline
idle. This allows sequential non-final chunks to preserve the accumulator
transaction across commands, while final completion still proves that compute,
input DMA, result DMA, and output drain are all idle. Composite protocol status
includes scheduler fault state, but the scheduler observes only the underlying
datapath error to avoid a combinational or sticky status feedback loop. The PE,
SA, feeder, storage blocks, DMA adapters, and compute data plane are unchanged.

### N8 fully-connected M4 issuer

`rtl/feeder/alexnet_n8_fc_m4_issuer.sv` converts the activation-buffer layout
`[K block][M position][8 K lanes]` into the unchanged M4xN8 SA issue boundary.
It buffers at most four 64-bit activation words, transposes them into up to
eight K cycles, requests exactly one resident `[K][N lane]` weight replay, and
issues activation and weight operands atomically. Descriptor fields provide K
count, M count, low-contiguous N mask, activation/weight context tags, and the
tile tag.

M1 through M4, N1 through N8, and a final partial K block are supported. FC6's
K=9,216 is intentionally not stored in this block: the parent splits it into
resident-weight chunks of at most 968 K words, and the existing INT32
partial-sum path accumulates those chunks. Invalid descriptors are rejected
before activation, weight, or tile ownership changes. Source metadata errors
are latched while the owned stream drains deterministically. The block adds no
BRAM, DSP, PE mode, or SA mode.

### Resident-weight accumulator M4xN8 FC datapath

`rtl/integration/alexnet_m4n8_fc_resident_weight_accum_datapath.sv` connects
the unchanged FC issuer, 968-word resident-weight bank, and one-segment
accumulator-aware M4xN8 base datapath. The wrapper is the sole replay and
tile/issue owner; it does not instantiate a second SA inside this FC path.

Each registered descriptor carries K count, M count, N mask, activation and
weight tags, accumulator context, tile tag, chunk index, and first/final flags.
Shape, accepted configuration, resident-weight context, and continuation
identity/index are checked before atomically launching the issuer and partial-
sum owner. Rejection has no child side effects and permits a corrected retry.
Non-final chunk indices cannot wrap. One FC output tile maps to M accumulator
words, one row of width M, with the same output tile tag across all K chunks.

Non-final completion preserves the INT32 transaction and produces no INT8
packets. The parent can release/refill weights at this boundary; a pending
configuration cannot interrupt continuation. Final `chunk_done` and
`transaction_done` wait for every output packet to transfer, not just for SA
or accumulator emission to finish. Completion pulses from the issuer and
accumulator are remembered independently. Weight fill/release and
reconfiguration are blocked throughout accepted-descriptor ownership.

Source/protocol errors latch `fault` until reset. An owned source-error chunk
drains, then reports `chunk_failed` instead of success. For a non-final error,
the partial-sum transaction stays quarantined and requires reset; for a final
error, the parent must still drain and discard all result packets. The output
ready/valid stream is not asynchronously suppressed when a fault appears.
Weight-fill/write and requant-configuration inputs retain the existing child
contracts; this wrapper is not an arbitrary malformed-DMA recovery engine.

The activation ABI is already packed `[chunk-local K block][M][K lane]`, with
one low-contiguous K-tail mask on each M word of the last block. It is not a
direct pool5 raster/feature-layout converter. Cross-chunk sums are INT32, but
the unchanged requant block still requires the final post-bias result within
signed-27 range and the frozen multiplier/shift ranges. The parent/model
range proof remains required; this is not unrestricted INT32 requantization.

### Activation-buffered resident-weight accumulator M4xN8 FC datapath

`rtl/integration/alexnet_m4n8_fc_activation_resident_weight_accum_datapath.sv`
adds one unchanged 512x64-bit activation bank around the unchanged FC
resident-accumulator path. At K<=968 and M<=4, `ceil(K/8)*M` needs at most
484 words. There is no activation ping-pong, compute duplication, pool5 layout
conversion, or AXIS/DMA attachment in this wrapper.

An activation fill descriptor contains K count, M count, and tensor tag. It
is registered and validated before committing the child bank. The physical
fill stream is `[chunk-local K block][M][8 K lanes]`: every word has mask
`FF`, every unused K-tail byte must be zero, tags must match the descriptor,
and `last` is true only on word `ceil(K/8)*M-1`. All M words of the last block
are checked for padding, not just the last physical word. The child memory
retains its single descriptor-wide `FF` mask; K/M and each read index
reconstruct the issuer's low-contiguous K-tail mask without changing the bank.

Compute descriptors first match the resident activation K/M/tag, then pass
through the inner FC weight/N/accumulator validation. The activation bank is
not consumed merely because the inner wrapper accepts a descriptor: its read
starts only when the validated issuer demands activation. Both outer and
inner rejections leave the input READY for a corrected retry, with no replay
or tile side effect. Accepted chunks block activation refill, weight-owner
changes, and reconfiguration until retirement. Final success waits for both
activation-read completion and the inner FC path's full output drain.

Malformed activation fills latch `fault` immediately, drain the declared
word count, report `activation_fill_failed`, and quarantine the bank until
reset without launching compute. The storage wrapper supplies corrected
count-derived `last` and zero padding to keep child ownership deterministic;
this never turns a bad external transfer into success. A sender that stops
early must reset the wrapper; missing words are not fabricated. Read-stream
metadata faults similarly drain an owned chunk and report `chunk_failed`,
not `transaction_done`; any final output from that transaction is discarded.

### FC DMA input/output datapath

`rtl/integration/alexnet_m4n8_fc_dma_io_datapath.sv` wraps the unchanged
activation-buffered FC path with the existing 128-bit DMA ingress and result
egress adapters. It serializes input transfer ownership and compute ownership;
it is not an overlapping/prefetch pipeline or a board AXI DMA IP instance.

Input descriptors contain destination, word/byte count, lane mask, tag, K,
and M. Destination 0 accepts padded FC activation with `ceil(K/8)*M` words,
M=1..4, and mask `FF`; destination 2 accepts K resident-weight words, M=0,
and a low-contiguous N mask. K must be 1..968 and byte count must equal eight
times word count. Pooled/reserved destinations, inconsistent geometry/counts,
and nonempty target owners are rejected before the DMA adapter or storage
commits. All fields are registered; changing external descriptor pins during
the transfer has no effect. A simultaneous input descriptor takes priority
over compute and weight release. Existing requant/router configuration
contracts, including N64 alignment, are unchanged.

Only the validated final chunk automatically arms a result descriptor, for
exactly M words using its captured tile tag/N mask and accepted destination/
N base. Inner activation-read activity proves that all inner validation has
passed, so a rejected final request cannot strand a result DMA owner. The
adapter is armed before consuming result packets; no result descriptor is
created for a non-final chunk. Non-final completion preserves partial sums;
final completion remembers core and adapter done independently and waits for
the last `m_axis_tvalid && m_axis_tready && m_axis_tlast` transfer and idle.

Input `TKEEP/TLAST`, activation-padding/read metadata, and output metadata
errors latch `fault` until reset. Owned descriptor-counted transfers keep
draining, but report input `dma_transfer_failed` or compute `chunk_failed`
instead of success. New descriptors/configuration/release are interlocked.
Correctable descriptor rejections do not set the sticky fault. A source that
stops before its declared count requires reset rather than fabricated data.
Raw `result_dma_transfer_done` and its counter include failed transfers;
`transaction_done` is the clean final-success indication, and faulted output
must be discarded.

This boundary proves delivery to the AXIS sink, not the downstream AXI DMA
IP's DDR-write completion or Linux buffer ownership. The board controller must
also wait for the actual DMA IP/software completion before consuming DDR.
Full K lengths here are individual output tiles, not complete FC layer loops,
trained-model accuracy, or camera-to-terminal classification.

### Runtime N8 output placement on one FC SA

The router and the single-accumulator FC wrapper chain now expose an opt-in
`RUNTIME_SLICE_INDEX` parameter (default 0) and a three-bit `cfg_slice_index`
input. With the option enabled, an accepted configuration selects N8 position
0..7 within the still-N64-aligned `cfg_n64_tile_base`. The tagged output base
is `cfg_n64_tile_base + 8*cfg_slice_index`; `egress_slice` identifies that
logical output position, not a newly instantiated physical SA. Destination,
mask, slice, and N base stay fixed until the current owner drains.

The router captures the selected slice at its empty configuration boundary.
The FC DMA wrapper captures the same slice/base on the same accepted config
and uses that shadow for the final-chunk result descriptor. Configuration
remains blocked throughout a partial-sum transaction, active input/compute,
and final AXIS backpressure, including after the inner core has retired.
Changing live placement pins does not change queued data or a later result
descriptor. No output placement is stored redundantly in each FIFO entry.

With the option disabled, `SLICE_INDEX` retains its original meaning and the
new input is ignored even when unknown. Existing in-tree fixed-mode callers
tie the new port explicitly; the non-accumulator and dual-accumulator/RS DMA
paths remain fixed-mode. PE, SA, requant arithmetic, memory payloads, and DMA
adapter RTL are unchanged. This is a configuration-interface extension, not
an automatic FC layer controller, DDR address generator, or board top.

The extended router regression reuses the independent fixed-slice C++ oracle
at each empty runtime configuration boundary. It checks all eight positions
at N64 bases 960 and 65472 (including the maximum legal N8 base 65528), all
destination values, N tails, full-FIFO turnover, and 113 blocked config cycles.
Fixed/runtime modes pass 343/354 checked cycles and 130 output packets each.
The runtime mode reports `positions=ff`; the fixed mode always stays slice 3
despite the same changing/unknown selection pins.

The runtime FC DMA regression repeats the full K=9216/4096 dense/DPI/error
suite, then traverses all eight positions in one N64 group with two K chunks
per position and checks FC8's last N8 placement N=992..999. It passes 22 clean
transactions, 48 completed chunks, 19 rejected chunks, three failed chunks,
22 rejected input descriptors, seven malformed input transfers, 24 result
transfers including failed outputs, and 17,688 K tokens. All eight positions
are observed. There are 960 blocked-future-config checks and 460 cycles of
inner-core retirement with S2MM still stalled. Live slice/base/destination
pins are deliberately poisoned after config acceptance. The unchanged
default-mode FC DMA regression retains its previous exact pass counters.

## Verification

### FC layer controller and full FC8 numerical integration

`rtl/control/alexnet_fc_layer_controller.sv` accepts one job for layer 6, 7,
or 8, M=1..4, and a 16-bit job tag. It schedules one layer, not the full
Conv/Pool/FC graph. N8 output tiles are the outer loop and K chunks of at most
968 are the inner loop; only one M4xN8 SA is used by
`rtl/integration/alexnet_m4n8_fc_layer_datapath.sv`.

| Layer | Full K | Outputs | N8 tiles | K chunks per tile | Final K chunk |
|---|---:|---:|---:|---:|---:|
| FC6 | 9216 | 4096 | 512 | 10 | 504 |
| FC7 | 4096 | 4096 | 512 | 5 | 224 |
| FC8 | 4096 | 1000 | 125 | 5 | 224 |

All three output counts are divisible by eight. FC8 stops at N=992..999,
slice 4 of the last N64 group; it does not emit the unused slices 5..7.
FC6/7 select activation-buffer destination 0 with ReLU enabled; FC8 selects
final-output destination 2 with ReLU disabled. Bias, multiplier, and shift
are supplied once per N8 tile by an external parameter service and captured
before configuration. Layer/job/N metadata and the frozen multiplier/shift
ranges are checked before the child can accept those parameters.

External services supply packed input words in response to logical read
requests and accept a result request before each final K chunk. Read requests
include layer/job, N base, K offset/count, destination, M/counts, and a tag;
they are not physical DDR addresses. The activation service must already
provide the padded `[K-block][M][K-lane]` layout; weights are `[K][N-lane]`.
The consuming activation bank is refilled for every N8/K chunk, with no
prefetch/overlap or full-layer activation-cache claim. Each completed chunk
releases its resident weight bank; nonfinal partial sums remain owned.

After the final result's AXIS transfer and core retirement, the controller
also waits for a matching external `result_complete` acknowledgement and
an empty weight bank before advancing N or asserting `layer_done`. The
service must issue that acknowledgement only after its actual transfer has
completed; the testbench's receiver is not proof of AXI DMA DDR completion.
Missing service input waits indefinitely rather than manufacturing data or
success. Job shape rejection is retryable without acquiring child owners.
Parameter/transfer/completion faults latch until joint reset; `layer_failed`
does not certify that every external transfer has drained. Unaccepted
requests may be canceled on fault; owned streams may drain in the unchanged
child. External services must quiesce/abort ownership before resetting both
controller and datapath and must discard failed-job output.

The standalone controller regression uses a behavioral downstream model.
It completes FC6 M4, FC7 M3, FC8 M1, and FC8 M2 (8,930 successful chunks),
rejects six invalid jobs, and tests fourteen parameter/service/downstream/
completion failures. Registered parameter capture, tag wrap, stale-weight
release, separated chunk/transaction pulses, early and late completion
acknowledgements, 3,831 config-stall cycles, 35,780 read-request-stall cycles,
and 7,744 delayed-commit checks all pass. This is controller geometry and
ownership coverage, not four full numerical FC layer executions.

The integrated regression completes all 125 N8 output tiles of FC8 M1:
625 K chunks, 512,000 SA K tokens, and all 1,000 INT8 outputs. It checks each
issued operand, final INT32 sums, routed coordinates, and packed AXIS data
against independent dense sums and the existing C++ DPI dot-product/requant
oracles. A scalar reduction plus an independently calculated fixture checksum
guards the test reference itself; no PE/SA/requant arithmetic was changed.
Synthetic data is used, not the trained checkpoint or camera input.

A malformed activation MM2S transfer with M3 drains without compute; joint
reset then permits the full FC8 run. A subsequent M3 tile receives correct
data but a wrong result-completion tag, which faults without advancing N.
Including those fault cases, the test checks 630 chunks, 516,096 K tokens,
1,261 input transfers, 291,250 MM2S beats, 126 result transfers, 128 result
words, and 127 S2MM beats. It includes 3,701 output-stall cycles, 128,805 CE
stall cycles, and 2,396 delayed-commit checks (seed 1178815577). The current
runtime-placement FC DMA regression also passes unchanged. The service ABI
and reproduction commands are documented in `rtl/README.md`.

### Earlier block regressions

The C++ DPI oracle and RTL simulation passed with deterministic seed
`1295273528`:

```text
ALEXNET_SA_M4N8_TEST_PASSED products=46552 results=1520 seed=1295273528
```

Coverage in this run includes signed packed-product corners inherited from the
PE regression, row/column skew pairing, random K=1..64, source bubbles, CE
stalls, M-tail masks, an inactive physical row, and simultaneous backpressure
on all 16 PE holdings.

The standalone PE regression also passed:

```text
ALEXNET_PACKED_PE_TEST_PASSED products=32135 results=412 seed=1105737217
```

The scanner and router C++ cycle-oracle regressions passed:

```text
ALEXNET_M4N8_SCANNER_TEST_PASSED beats=272
ALEXNET_N8_ROUTER_TEST_PASSED cycles=161 packets=66
```

The requant pipeline passed a bit-exact C++ DPI comparison across signed-27
corners, N tails, two parameter sets, ReLU/saturation cases, random values,
backpressure, and an in-flight configuration request:

```text
ALEXNET_N8_REQUANT_TEST_PASSED beats=769 configs=2 seed=1511506142
```

The integrated slice regression drove the router FIFO genuinely full and
checked final packet data and coordinates against the C++ requant oracle:

```text
ALEXNET_M4N8_N8_OUTPUT_SLICE_TEST_PASSED tiles=86 packets=249 configs=3 maxq=64 seed=1869968467
```

The complete base-datapath regression compares every packed PE product and
every final INT8 packet against the C++ DPI oracles. It covers INT8 corners,
M=1..4, N=1/4/8, random K bubbles, CE stalls, full-FIFO output backpressure,
and three atomic configuration epochs:

```text
ALEXNET_M4N8_BASE_DATAPATH_TEST_PASSED tiles=68 k_tokens=608 packets=200 configs=3 maxq=64 seed=1295270468
```

The max-pool regression compares every output window against the C++
`maxpool_ref`. It covers signed INT8 corners, all three AlexNet pool input
shapes, lane tails, source bubbles, an even-dimension completion tail, and
output stalls up to eleven cycles:

```text
ALEXNET_N8_MAXPOOL3X3_TEST_PASSED frames=5 inputs=3972 outputs=940 maxstall=11 seed=1511472273
```

The activation-bank DPI regression uses the C++ ownership/data oracle at depth
boundaries 1, 17, 511, and 512. It checks four lane masks, invalid-lane zeroing,
wrong-owner request rejection, full sequential addressing, last-word release,
and read stalls up to twelve cycles:

```text
ALEXNET_N8_ACTIVATION_BANK_TEST_PASSED transactions=4 words=1041 maxstall=12 seed=1797868823
```

The activation ping-pong DPI regression compares both child-bank states,
word counts, queue head, source owner, read owner, data, masks, indices, last,
and tensor tags against `activation_pingpong_ref`. It covers 1/17/55/169/256/
511/512-word tensors, both direct and pooled sources, a full two-entry READY
queue, malformed descriptor/data backpressure, eight mismatched read tags,
non-owner source traffic, six same-edge role exchanges, and 1,023 cycles of
actual cross-bank fill/read overlap:

```text
ALEXNET_N8_ACTIVATION_PINGPONG_TEST_PASSED transactions=8 words=1524 rejects=8 wrongsrc=172 overlap_cycles=1023 role_swaps=6 maxstall=18 seed=1798999329
```

The dual-segment activation DPI regression compares the aggregate owner and
both unchanged child ping-pong units against the C++ reference. It covers
513/514/600/729/777/1,024-word tensors, both write sources, a full aggregate
READY queue, tag mismatch rejection, non-owner traffic, A/B overlap, and
backpressure on both sides of the global 511-to-512 segment transition:

```text
ALEXNET_N8_ACTIVATION_DUAL_SEGMENT_PINGPONG_TEST_PASSED transactions=6 words=4157 rejects=6 wrongsrc=401 overlap_cycles=3577 role_swaps=4 transitions=6 boundary_stalls=12 maxstall=20 seed=1800117809
```

The RS feeder regression compares every one of 322,143 emitted K tokens against
`window_ref`. It covers all three AlexNet kernel/stride/padding modes, the
actual 224x224 conv1 input and its three channels, actual 27x27 and 13x13
feature shapes, all five explicit ring-bank boundaries, M3/M1 row tails,
padding zeroes, source bubbles, and output stalls:

```text
ALEXNET_N8_RS_M4_FEEDER_TEST_PASSED frames=4 inputs=51330 tokens=322143 maxstall=13 seed=1797936343
```

The complete RS-datapath regression uses the C++ window, packed-product, and
requant oracles together. It covers all three convolution modes, row-local M
tails, weight-context stalls, independent activation/weight bubbles, compute
CE stalls, output backpressure, descriptor sequencing, and exact final INT8
packet data:

```text
ALEXNET_M4N8_RS_DATAPATH_TEST_PASSED frames=3 tiles=27 k_tokens=4609 packets=88 configs=3 maxq=4 seed=1901341241
```

The weight-tile-bank DPI regression compares all replayed words and descriptor
metadata against `weight_tile_bank_ref`. It covers K depth boundaries 1, 17,
967, and 968, four N-tail masks, signed INT8 corners, eight complete rewinds,
twelve mismatched-context requests, fill bubbles, and output stalls up to
nineteen cycles:

```text
ALEXNET_N8_WEIGHT_TILE_BANK_TEST_PASSED transactions=4 replays=8 words=2940 mismatches=12 maxstall=19 seed=1798991401
```

The resident-weight RS regression fills one weight tile per frame and compares
every final packet against the C++ window, packed-product, and requant oracles.
It covers all three convolution modes, 27 spatial rewinds, frame-descriptor
context rejection, fill bubbles, compute stalls, output backpressure, and
attempted release/refill while a frame owns the bank:

```text
ALEXNET_M4N8_RS_RESIDENT_WEIGHT_DATAPATH_TEST_PASSED frames=3 tiles=27 replays=27 replay_words=4609 fill_words=635 rejects=6 packets=88 configs=3 maxq=4 seed=1935232045
```

The partial-sum-bank DPI regression compares every final signed INT32 lane
against `partial_sum_bank_ref`. It covers depth boundaries 1, 17, 511, and 512,
the conv4 maximum of 48 eight-channel chunks over a 13x13 raster, N tails,
first/continuation/final ownership, 185 rejected descriptors, 65 out-of-order
words, source bubbles, and output stalls:

```text
ALEXNET_N8_INT32_PARTIAL_SUM_BANK_TEST_PASSED transactions=5 chunks=65 ingress_words=14815 egress_words=1210 descriptor_rejects=185 blocked_words=65 maxstall=17 seed=1940396493
```

The accumulator-aware output-slice regression compares partial accumulation
and final INT8 packets against the C++ partial-sum and requant oracles. It
covers a 13x13 raster with 48 chunks, final-only packet release, N tails,
descriptor-context rejection, source bubbles, scanner stalls, and a genuinely
full 64-entry router FIFO:

```text
ALEXNET_M4N8_N8_ACCUM_OUTPUT_SLICE_TEST_PASSED transactions=3 chunks=52 tiles=2518 accum_words=8169 packets=196 descriptor_rejects=98 configs=3 maxq=64 seed=1957835237
```

The accumulator-aware complete-base regression drives actual signed INT8
activation/weight K tokens through all 16 packed PEs and compares packed
products, cross-chunk INT32 partial sums, and final requantized packets against
the C++ oracles. It covers the one-bank 13x13 raster with 48 chunks, M/N tails,
source bubbles, CE stalls, final-only packet release, a full router FIFO, and a
configuration held pending across 54 accepted compute tiles:

```text
ALEXNET_M4N8_ACCUM_BASE_DATAPATH_TEST_PASSED transactions=3 chunks=52 tiles=2554 k_tokens=2613 accum_words=8259 packets=226 configs=3 maxq=64 pending_tiles=54 seed=1975730756
```

The resident-weight accumulator RS regression exercises the actual conv4
one-bank shape: 48 input-channel chunks, each carrying a 13x13 raster with
eight channels and K=72. Every chunk fills one resident weight tile and replays
it for all 52 spatial groups. The test compares the final 169 INT8 packets
against the C++ window, packed-product, and requant oracles; no non-final chunk
may expose a packet. It also covers source/compute stalls, attempted mid-chunk
weight replacement, first/continuation context rejection, a full router FIFO,
and 47 continuation chunks accepted while a new configuration is pending:

```text
ALEXNET_M4N8_RS_RESIDENT_WEIGHT_ACCUM_DATAPATH_TEST_PASSED chunks=48 tiles=2496 replays=2496 replay_words=179712 fill_words=3456 source_words=8112 packets=169 rejects=4 configs=2 maxq=64 pending_chunks=47 seed=1923401777
```

The dual-accumulator resident-weight regression exercises the actual conv2
shape: twelve eight-input-channel chunks, K=200 per chunk, 27x27 spatial
outputs, and the 512/217 bank boundary. It compares all 729 final packets with
the C++ window, packed-product, cross-chunk accumulation, and requant oracles.
It also covers 2,268 resident-weight replays, source/compute/output stalls,
context rejection, a full router FIFO, and eleven continuation chunks accepted
while a configuration is pending:

```text
ALEXNET_M4N8_RS_RESIDENT_WEIGHT_DUAL_ACCUM_DATAPATH_TEST_PASSED chunks=12 tiles=2268 replays=2268 replay_words=453600 fill_words=2400 source_words=8748 packets=729 rejects=4 configs=2 maxq=64 pending_chunks=11 seed=1926416433
```

The activation-buffered integration regression fills two complete 27x27 N8
conv2 input chunks, using the direct source for the first tensor and pooled
source for the second. It overlaps the second fill with the first activation
read, crosses the 512/217 segment boundary twice, and checks all feeder
windows, packed products, accumulated results, and 729 final requantized
packets against the C++ DPI oracles. It also accepts and rejects mismatched
activation-tag, activation-geometry, and resident-weight-context commands
without consuming either storage owner:

```text
ALEXNET_M4N8_RS_ACTIVATION_RESIDENT_WEIGHT_DUAL_ACCUM_DATAPATH_TEST_PASSED chunks=2 activation_words=1458 tiles=378 replays=378 replay_words=75600 weight_words=400 packets=729 overlap_cycles=893 transitions=2 rejects=3 maxq=64 seed=1973602625
```

The DMA-ingress regression transfers a 729-word activation tensor, a 17-word
pooled tensor, a 200-word resident-weight tile, and one three-word stream-error
case through randomized source bubbles and destination backpressure. It checks
low-word-first 128-to-64-bit unpacking, the odd activation tail, delayed owner
commit, six invalid descriptor classes, and sticky stream-error clearing:

```text
ALEXNET_N8_DMA_INGRESS_TEST_PASSED transfers=4 words=949 axis_beats=476 rejects=6 activation_commits=3 weight_commits=1 owner_wait_cycles=26 maxstall=3 stream_errors=1 seed=1965855143
```

The DMA-fed integration regression sends two complete conv2-shaped chunks
through the real AXIS input and storage owners: 729 direct activation words and
200 weights for chunk zero, then 729 pooled activation words overlapping the
first chunk's read and 200 replacement weights. It checks 729 final packets,
random source/compute/egress stalls, a full 64-entry output FIFO, owner-safe
descriptor rejection, and six cycles of DMA-error launch interlock:

```text
ALEXNET_M4N8_RS_DMA_ACTIVATION_RESIDENT_WEIGHT_DUAL_ACCUM_DATAPATH_TEST_PASSED chunks=2 dma_transfers=4 dma_words=1858 axis_beats=930 tiles=378 replays=378 packets=729 overlap_cycles=1385 transitions=2 dma_rejects=1 interlock_cycles=6 maxq=64 seed=1993616153
```

The DMA-result regression covers an even transfer, a complete 729-word conv2
raster, an odd lane-tail transfer, and a malformed-metadata transfer under
random source bubbles and S2MM backpressure. It checks six descriptor rejection
classes, all six packet-metadata error classes, low-word-first packing, masked
bytes, exact odd-tail signaling, output stability, and sticky-error clearing:

```text
ALEXNET_N8_DMA_RESULT_EGRESS_TEST_PASSED transfers=4 packets=763 axis_beats=383 rejects=6 metadata_error_packets=6 source_backpressure_cycles=3 maxstall=2 seed=2052266449
```

The full DMA-loop regression sends two complete conv2-shaped chunks through
the real MM2S input, activation/weight owners, compute datapath, result router,
and S2MM output. It checks all 729 result words and exactly 365 output beats,
including the odd final half-beat, concurrent input fill and compute, a full
64-entry output FIFO under result-DMA backpressure, invalid result-descriptor
rejection, and six cycles of result-error chunk interlock:

```text
ALEXNET_M4N8_RS_DMA_IO_ACTIVATION_RESIDENT_WEIGHT_DUAL_ACCUM_DATAPATH_TEST_PASSED chunks=2 input_dma_transfers=4 input_dma_words=1858 input_axis_beats=930 result_dma_transfers=1 result_words=729 result_axis_beats=365 tiles=378 replays=378 overlap_cycles=1361 transitions=2 result_rejects=1 result_interlock_cycles=6 maxq=64 max_s2mm_stall=397 seed=2067869155
```

The scheduler regression covers a locally rejected command, one successful
non-final command, a downstream-rejected input descriptor, and a successful
final command after fault clear/restart. It then runs a full-geometry Conv1
direct-activation-stream command and confirms that no activation DMA
descriptor is issued. It randomizes request readiness, checks descriptor
stability under backpressure, forces stale-weight release, holds a final chunk
until S2MM is active, and delays error clear for four cycles while owned work
remains busy:

```text
ALEXNET_DMA_CHUNK_SCHEDULER_TEST_PASSED commands=5 completed=3 rejected=2 conv1_streaming=1 input_descriptors=6 result_descriptors=2 chunks=3 weight_releases=4 input_stall_cycles=15 result_stall_cycles=6 chunk_stall_cycles=9 recovery_wait_cycles=4 seed=2085820833
```

The scheduled full-loop regression drives four software commands through the
real child blocks: one locally rejected cross-field relationship, one malformed
activation transfer rejected by DMA ingress followed by clear/restart, one
successful non-final direct-activation conv2 chunk, and one successful final
pooled-activation chunk. It checks all 729 result words and 365 S2MM beats,
automatic weight release, the open non-final accumulator boundary, final full
idle, a full 64-entry output FIFO, and 397 cycles of forced result stall:

```text
ALEXNET_M4N8_RS_DMA_SCHEDULED_IO_DATAPATH_TEST_PASSED commands=4 completed=2 rejected=2 input_dma_transfers=4 input_dma_words=1858 input_axis_beats=930 result_dma_transfers=1 result_words=729 result_axis_beats=365 chunks=2 tiles=378 replays=378 transitions=2 input_descriptor_rejects=1 fault_clears=2 maxq=64 max_s2mm_stall=397 seed=2103593495
```

The FC issuer regression covers the maximum current resident-weight chunk
K=968 with M4/N8, M3/N5 and M1/N1 tails, K=10 and K=9 partial activation
blocks, randomized replay/activation/tile/issue backpressure, descriptor
rejection before child ownership, and deterministic completion after one bad
activation tag and one bad weight K tag:

```text
ALEXNET_N8_FC_M4_ISSUER_TEST_PASSED descriptors=5 completed=4 rejected=1 replays=4 activation_words=494 tiles=4 k_tokens=994 replay_stall_cycles=2 activation_stall_cycles=2061 tile_stall_cycles=1 issue_stall_cycles=328 source_metadata_errors=2 seed=2133940937
```

The FC resident-accumulator regression compares every scanned chunk dot product
and final INT32 sum against an independent global-K dense reference, then every
INT8 packet against the C++ requant oracle. It covers FC6-length K=9216/M4/N8
in ten chunks, K=4096/M3/N5 and K=4096/M1/N1 in five chunks each, and K=17/M2/N2
split at a non-N8-aligned 10/7 boundary. These are individual output tiles,
not complete 4096/1000-output FC layers or a trained-model accuracy test.

Coverage includes M1..4, N/K tails, full-range INT8 operands, intermediate
INT32 sums exceeding signed-27 and cancelling back into the legal final
requant range, 15 recoverable shape/context rejections, pending configuration,
simultaneous release/descriptor priority, randomized source gaps and CE pauses,
and final-output backpressure. Two bad activation-tag cases separately prove
final and non-final fault quarantine, followed by reset recovery. The 64-entry
output FIFO peaks at four words in this one-tile test; full-FIFO coverage
remains in the existing router/RS regressions.

```text
ALEXNET_M4N8_FC_RESIDENT_WEIGHT_ACCUM_DATAPATH_TEST_PASSED descriptors=40 completed=23 rejected=15 failed=2 transactions=5 replays=25 k_tokens=17451 activation_words=6672 weight_words=17451 partial_words=70 final_int32_words=14 output_words=14 output_stall_cycles=244 ce_stall_cycles=4256 owner_checks=33523 maxq=4 seed=1178819095
```

The activation-buffered FC regression repeats the full K=9216/4096 output-
tile reductions through actual BRAM writes/reads and independently compares
every read payload, reconstructed mask, partial INT32 word, final INT32 word,
and DPI-requantized INT8 packet. Additional cases cover all K-tail lengths
1..7, minimum K=1/M4, the maximum 484-word fill, 18 outer/inner compute
rejections without consuming the input, and four malformed fill descriptors.
Six bad-fill cases check tensor tag, fixed mask, early/missing `last`, and
nonzero padding in the first/last M word of a partial K block. Two injected
read-tag faults verify final and non-final drain/quarantine, followed by reset
recovery. Randomized CE and source gaps, activation-read stalls, pending
configuration, owner-change probes, and final-output stalls are also checked.

```text
ALEXNET_M4N8_FC_ACTIVATION_RESIDENT_WEIGHT_ACCUM_DATAPATH_TEST_PASSED descriptors=51 completed=31 rejected=18 failed=2 transactions=13 fills=43 fill_completed=33 fill_rejected=4 fill_failed=6 reads=33 read_words=6714 tail_words=33 replays=33 k_tokens=17536 activation_write_words=6750 weight_words=17536 partial_words=93 final_int32_words=37 output_words=37 output_stall_cycles=572 read_stall_cycles=21774 ce_stall_cycles=4450 owner_checks=30426 max_activation_words=484 maxq=4 seed=1178812738
```

The FC DMA regression drives actual 128-bit low-word-first input beats and
compares unpacked memory writes, activation reads, dense-reference partial/
final INT32 sums, DPI-requantized packets, and packed S2MM beats. It repeats
the K=9216/4096 tile cases, M1..4, all K-tail lengths, and minimum K=1. Twenty-
two input descriptors and nineteen compute descriptors are rejected without
owner side effects, including an invalid final command with no result arming.
Seven malformed MM2S transfers cover bad `TKEEP`, early/missing `TLAST` on
activation and weight streams, and bad activation padding. Two injected read
errors (final/non-final) and one output-metadata error drain and quarantine
correctly; reset recovery is verified after each case. Final-output stalls
include 266 cycles where the core has already retired but S2MM is still
blocked, directly exercising the outer completion guard. The result FIFO
peaks at two entries in this test; full-FIFO coverage remains in child tests.

```text
ALEXNET_M4N8_FC_DMA_IO_DATAPATH_TEST_PASSED descriptors=53 completed=31 rejected=19 failed=3 transactions=13 dma_commands=97 dma_completed=68 dma_rejected=22 dma_failed=7 mm2s_beats=12166 result_transfers=15 s2mm_beats=23 s2mm_words=40 odd_inputs=20 odd_outputs=6 replays=34 k_tokens=17543 activation_words=6741 weight_words=17570 partial_words=96 output_stall_cycles=602 read_stall_cycles=21837 ce_stall_cycles=4516 owner_checks=30185 early_core_retire_cycles=266 max_activation_words=484 maxq=2 seed=1178813517
```

## 200 MHz OOC results

Rows describe the source hashes recorded with each measurement. Historical
fixed-mode reports are preserved; the runtime-placement row is the newly
routed FC variant, not a resynthesis of every earlier wrapper revision.

| Block | CLB LUT | LUT logic | LUT SRL | FF | BRAM36 | DSP48E2 | WNS | WHS | Route errors |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| packed PE | 86 | 86 | 0 | 111 | 0 | 1 | +2.796 ns | +0.046 ns | 0 |
| M4xN8 base tile | 1,408 | 1,367 | 41 | 2,200 | 0 | 16 | +1.881 ns | +0.046 ns | 0 |
| M4xN8 result scanner | 407 | 407 | 0 | 33 | 0 | 0 | +1.874 ns | +0.150 ns | 0 |
| N8 requant | 1,639 | 1,639 | 0 | 447 | 0 | 8 | +0.940 ns | +0.055 ns | 0 |
| N8 output router | 152 | 54 | 0 | 46 | 0 | 0 | +2.396 ns | +0.097 ns | 0 |
| M4xN8 N8 output slice | 2,129 | 2,033 | 0 | 512 | 0 | 8 | +0.798 ns | +0.040 ns | 0 |
| Complete M4xN8 base datapath | 3,536 | 3,399 | 41 | 2,718 | 0 | 24 | +0.745 ns | +0.039 ns | 0 |
| N8 max-pool 3x3/s2 | 425 | 425 | 0 | 389 | 1 | 0 | +0.514 ns | +0.096 ns | 0 |
| N8 activation bank 512x64 | 92 | 92 | 0 | 112 | 1 | 0 | +2.220 ns | +0.059 ns | 0 |
| N8 activation A/B ping-pong | 353 | 353 | 0 | 295 | 2 | 0 | +1.524 ns | +0.064 ns | 0 |
| N8 dual-segment activation A/B ping-pong | 662 | 662 | 0 | 622 | 4 | 0 | +1.378 ns | +0.055 ns | 0 |
| N8 RS M4 window feeder | 590 | 590 | 0 | 423 | 5 | 0 | +0.594 ns | +0.092 ns | 0 |
| Complete M4xN8 RS datapath | 4,235 | 4,098 | 41 | 3,163 | 5 | 24 | +0.339 ns | +0.040 ns | 0 |
| N8 weight tile bank 968x64 | 109 | 109 | 0 | 132 | 2 | 0 | +2.023 ns | +0.064 ns | 0 |
| Resident-weight M4xN8 RS datapath | 4,359 | 4,222 | 41 | 3,301 | 7 | 24 | +0.755 ns | +0.035 ns | 0 |
| N8 INT32 partial-sum bank 512x256 | 791 | 791 | 0 | 649 | 4 | 0 | +0.907 ns | +0.055 ns | 0 |
| Accumulator-aware M4xN8 N8 output slice | 3,172 | 3,076 | 0 | 1,157 | 4 | 8 | +0.475 ns | +0.055 ns | 0 |
| Accumulator-aware complete M4xN8 base datapath | 4,511 | 4,374 | 41 | 3,329 | 4 | 24 | +0.601 ns | +0.036 ns | 0 |
| Resident-weight accumulator M4xN8 RS datapath | 5,272 | 5,135 | 41 | 3,919 | 11 | 24 | +0.479 ns | +0.037 ns | 0 |
| Resident-weight dual-accumulator M4xN8 RS datapath | 6,431 | 6,294 | 41 | 4,492 | 15 | 24 | +0.382 ns | +0.046 ns | 0 |
| Activation-buffered resident-weight dual-accumulator M4xN8 RS datapath | 7,338 | 7,201 | 41 | 5,424 | 19 | 24 | +0.495 ns | +0.046 ns | 0 |
| N8 DMA ingress, 128-bit AXIS | 115 | 115 | 0 | 250 | 0 | 0 | +1.948 ns | +0.100 ns | 0 |
| DMA-fed activation-buffered resident-weight dual-accumulator M4xN8 RS datapath | 7,382 | 7,245 | 41 | 5,674 | 19 | 24 | +0.289 ns | +0.046 ns | 0 |
| N8 DMA result egress, 128-bit AXIS | 241 | 241 | 0 | 369 | 0 | 0 | +1.852 ns | +0.055 ns | 0 |
| Full-DMA-loop activation-buffered resident-weight dual-accumulator M4xN8 RS datapath | 7,756 | 7,619 | 41 | 6,040 | 19 | 24 | +0.290 ns | +0.046 ns | 0 |
| Registered DMA chunk scheduler | 135 | 135 | 0 | 399 | 0 | 0 | +2.123 ns | +0.099 ns | 0 |
| Scheduler-controlled full-DMA-loop M4xN8 RS datapath | 7,775 | 7,638 | 41 | 6,440 | 19 | 24 | +0.375 ns | +0.046 ns | 0 |
| N8 fully-connected M4 issuer | 353 | 353 | 0 | 440 | 0 | 0 | +1.982 ns | +0.098 ns | 0 |
| Resident-weight accumulator M4xN8 FC datapath | 4,814 | 4,677 | 41 | 4,029 | 6 | 24 | +0.576 ns | +0.032 ns | 0 |
| Activation-buffered resident-weight accumulator M4xN8 FC datapath | 5,071 | 4,934 | 41 | 4,371 | 7 | 24 | +0.500 ns | +0.034 ns | 0 |
| Full-DMA-loop activation-buffered M4xN8 FC datapath | 5,534 | 5,397 | 41 | 5,108 | 7 | 24 | +0.396 ns | +0.044 ns | 0 |
| Runtime-placement full-DMA-loop M4xN8 FC datapath | 5,540 | 5,403 | 41 | 5,075 | 7 | 24 | +0.539 ns | +0.046 ns | 0 |
| FC6/7/8 layer controller | 418 | 418 | 0 | 577 | 0 | 0 | +1.026 ns | +0.090 ns | 0 |
| Controller-owned M4xN8 FC layer datapath | 5,820 | 5,683 | 41 | 4,897 | 7 | 24 | +0.497 ns | +0.046 ns | 0 |
| Shared Conv/FC M4xN8 compute top, 4096-word accumulator | 9,063 | 8,926 | 41 | 7,721 | 42 | 24 | +0.017 ns | +0.046 ns | 0 |
| Conv1..FC8 logical graph controller | 94 | 94 | 0 | 38 | 0 | 0 | +2.051 ns | +0.089 ns | 0 |
| Pool5-to-FC6 flatten reader | 311 | 311 | 0 | 291 | 0 | 0 | +0.843 ns | +0.064 ns | 0 |
| Graph-connected Conv1..FC8 M4xN8 compute top | 8,878 | 8,741 | 41 | 7,355 | 42 | 24 | +0.008 ns | +0.031 ns | 0 |

The M4xN8 result is fully routed, has no unconstrained internal endpoints, and
meets all timing constraints. DRC reports only `RTSTAT-10` on unconsumed OOC
output ports; this is an expected top-level-boundary warning, not an internal
routing failure.

The router's 64x85-bit packet storage uses 98 distributed-RAM LUTs and zero
BRAM. Moving static descriptor fields out of each FIFO entry reduced one router
from 194 to 152 LUT; eight slices therefore estimate to 1,216 LUT. Its
`RTSTAT-10` warning is on unused secondary outputs of inferred RAM64M8
primitives; all 95 routable router nets are fully routed.

The requant block maps each `(accumulator + bias) * multiplier` lane into one
DSP48E2 and uses all A/B/D/AD/M/P pipeline registers. Its symmetric rounding
bias formulation keeps the final slice to 1,639 LUT, and the fully registered
DSP mapping has no `DPOP-4` pipeline warnings. The final design has zero
unconstrained endpoints and all 1,843 routable nets are fully routed. Its only
DRC warning is the expected `RTSTAT-10` on unconsumed OOC output ports. Eight
parallel N8 slices would scale to 64 DSP48E2, matching the frozen N64 contract;
the measured single-slice arithmetic estimate is 13,112 LUT and 3,576 FF
before cross-slice optimization.

The integrated slice uses 96 LUTRAM LUTs for the FIFO and zero BRAM. Cross-
module optimization saves 69 LUT and 14 FF versus the sum of the three
standalone results. All 2,502 routable nets are fully routed, all timing
endpoints are constrained, and the only DRC warning is `RTSTAT-10` on unused
secondary outputs of the inferred RAM64M8 primitives. Eight copies for the
eventual N64 boundary estimate to 17,032 LUT, 4,096 FF, and 64 DSP48E2 before
cross-slice optimization.

The complete base datapath also uses 96 LUTRAM LUTs and zero BRAM; its remaining
41 memory LUTs are the SA skew SRLs. The final route contains 6,082 fully routed
routable nets, zero routing errors, and zero unconstrained internal endpoints.
The only DRC warning is the same expected `RTSTAT-10` on unused secondary
RAM64M8 outputs. Compared with the separate SA plus output-slice measurements,
integration changes the result by -1 LUT and +6 FF, so the wrapper control is
not hiding a material resource increase. This is the measured local baseline;
it is not extrapolated here as a complete N64 accelerator.

The max-pool slice contains 620 fully routed routable nets, zero unconstrained
internal endpoints, and no DRC violations. The single-line vertical reuse
halves its line-buffer allocation from the initial two-BRAM implementation.
Eight independent N8 slices therefore estimate to 3,400 LUT, 3,112 FF, and
8 BRAM36 before cross-slice optimization, matching the provisional streaming
pool allocation in the frozen activation-memory contract.

The activation bank maps its complete 4 KiB payload to one RAMB36E2 and adds
only 92 LUT and 112 FF for ownership, tail masking, counters, and the elastic
read stage. All 187 routable nets are fully routed, with zero unconstrained
internal endpoints and no DRC violations. Capacity scaling is therefore one
BRAM36 per additional 512 N8 words; A/B overlap is achieved by separate bank
instances rather than adding a multi-owner port to this unit.

The activation ping-pong boundary maps both 4 KiB payloads to exactly two
RAMB36E2 primitives and uses no LUTRAM, SRL, or DSP. Relative to two separately
measured activation banks, ordered READY/source/tag ownership adds 169 CLB LUT
and 71 FF. All 672 routable nets are fully routed, all 1,211 setup/hold
endpoints meet 200 MHz, and DRC reports zero violations.

The dual-segment activation boundary maps two 8 KiB logical sets to exactly
four RAMB36E2 primitives, with no LUTRAM, SRL, or DSP. Compared with two
standalone activation ping-pong units, pair ownership and cross-segment stream
control save 44 CLB LUT after integration and add 32 FF. All 1,377 routable
nets are fully routed, all 2,342 setup/hold endpoints meet 200 MHz, and DRC
reports zero violations.

The RS feeder's five explicit 512x64-bit banks hold only the maximum K11
padded-row working set. The routed unit uses no LUTRAM or DSP, all routable nets
complete without errors, all internal endpoints are constrained, and DRC has
zero violations. This is one N8 input-channel slice feeding one logical M4
tile; it is not multiplied by eight because input-channel groups are scheduled
through the same compute tile rather than emitted as eight simultaneous N
outputs.

The N8 fully-connected M4 issuer uses 353 LUT and 440 FF with no LUTRAM, SRL,
BRAM, or DSP. Its four 64-bit registers are the complete activation transpose
storage; weight storage remains in the existing resident owner. All 526
routable nets are fully routed, all 807 setup/hold endpoints meet 200 MHz,
there are zero unconstrained internal register endpoints, and DRC reports zero
violations.

The integrated FC path uses 4,814 LUT and 4,029 FF, with six BRAM36 (two
resident-weight and four INT32 partial-sum banks) and the unchanged 24 DSP48E2
(16 compute, eight requant). Its 137 memory LUTs remain 96 FIFO LUTRAM plus
41 SA skew SRLs. All 8,782 routable nets are fully routed and all 18,937
setup/hold endpoints meet the 200 MHz OOC constraints, including specified
input/output delays. There are no unconstrained internal endpoints, latches,
or combinational loops; DRC reports only expected `RTSTAT-10` on unused
inferred-memory secondary outputs/OOC outputs. This is local block timing,
not full-board PS-clock/AXI/bitstream signoff or camera throughput evidence.

The activation-buffered FC path adds 257 LUT, 342 FF, and one RAMB36E2 to the
measured resident-accumulator FC path. It uses 5,071 LUT, 4,371 FF, seven
BRAM36, and the same 24 DSP48E2; FIFO LUTRAM remains 96 LUT and SA skew SRLs
remain 41 LUT. All 9,460 routable nets are fully routed and all 20,132
setup/hold endpoints meet the 200 MHz OOC constraints at WNS +0.500 ns and
WHS +0.034 ns. Timing checks report no unconstrained internal endpoints,
missing I/O delays, latches, or combinational loops. The only DRC warning is
expected `RTSTAT-10` on unused inferred-memory secondary/OOC outputs. The
OOC clock/partition-pin assumptions are not board-level timing signoff.

The FC DMA loop adds 463 LUT and 737 FF to the buffered FC path, with no
additional BRAM or DSP: 5,534 LUT, 5,108 FF, seven BRAM36, and 24 DSP48E2.
FIFO LUTRAM remains 96 LUT and SA SRLs remain 41 LUT. All 10,545 routable
nets are routed, all 22,299 setup/hold endpoints meet the 200 MHz constraints
at WNS +0.396 ns/WHS +0.044 ns, and there are no missing I/O constraints,
unconstrained internal endpoints, latches, or combinational loops.

DRC has two nonfatal warnings: the usual `RTSTAT-10` OOC/unused-memory-output
warning and `DPOP-3` for requant lane 7 with DSP `PREG=0`. A read-only routed
checkpoint inspection found 45 downstream FDRE endpoints on that lane's
P outputs; lanes 0..6 retain `PREG=1`. The mapping evidence is recorded in
`reports/m4n8_fc_dma_io_datapath/200mhz/requant_dsp_mapping.rpt`. The DSP
internal-pipelining advisory is not waived as an unused-port warning. Timing
passes, but this run is not DRC-warning-free or a full-board timing/functional
signoff. PE, SA, requant RTL, and DMA adapter RTL remain unchanged.

The runtime-placement FC DMA variant is fully routed at the single 200 MHz
target: 5,540 LUT, 5,075 FF, seven BRAM36, and 24 DSP48E2. Its 96 LUTRAM LUTs
and 41 SA skew SRLs are unchanged. Relative to the recorded fixed-mode run,
the integrated result is +6 LUT and -33 FF; the FF/timing differences include
implementation-dependent optimization and are not a guaranteed register
saving or an architectural speedup. WNS is +0.539 ns, WHS +0.046 ns, TNS/THS
zero, and all 22,250 setup/hold endpoints meet constraints. All 10,532
routable nets are routed with zero routing errors, no unconstrained internal
endpoints, no missing I/O delays, no latches, and no combinational loops.
DRC reports only the expected `RTSTAT-10` OOC/unused-output warning; the prior
fixed-mode run's `DPOP-3` warning is not present in this variant. No PE or
requant RTL was changed to achieve this. OOC clock/partition-port assumptions
still do not constitute full-board timing signoff or post-route equivalence.

The runtime and fixed router/FC DMA tests plus seven affected child/shared
path regressions pass. These include the accumulator slice/base, resident
and buffered FC, non-accumulator output slice, resident RS accumulator, and
scheduler-controlled RS DMA loop. A summary with test-source hashes is in
`reports/m4n8_fc_dma_runtime_placement/200mhz/regression_summary.txt`.

The FC layer controller alone uses 418 logic LUTs and 577 FF, with no BRAM,
LUTRAM, SRLs, or DSP. Its 377 routable nets are fully routed, all 2,512
setup/hold endpoints meet 200 MHz (WNS +1.026 ns, WHS +0.090 ns), and DRC has
zero violations. The parameter-response register is included in this count.

The controller-owned FC layer integration uses 5,820 LUT, 4,897 FF, seven
BRAM36, and 24 DSP48E2. The 96 FIFO LUTRAM LUTs and 41 SA skew SRLs remain.
All 10,401 routable nets are routed; all 21,634 setup/hold endpoints meet
200 MHz at WNS +0.497 ns and WHS +0.046 ns. TNS/THS and routing errors are
zero; there are no unconstrained internal endpoints, missing I/O delays,
latches, or combinational loops. DRC reports only the expected `RTSTAT-10`
OOC-output warning and no DSP pipeline warning. The wrapper does not export
the earlier core's debug counters and fixes FC geometry/masks, so its lower
FF total must not be interpreted as a negative controller cost. No extra SA,
memory payload bank, or DSP was instantiated. These are OOC constraints, not
board clock/partition-pin timing signoff or post-route functional equivalence.

The complete RS datapath retains exactly the feeder's five RAMB36E2 and the
base datapath's 24 DSP48E2. Its 137 non-logic LUTs are the existing 96 router
LUTRAM LUTs plus 41 SA skew SRLs. Integration adds only 109 CLB LUT and 22 FF
over the separate base-datapath and feeder measurements. All 7,520 routable
nets are fully routed, all internal register endpoints are clocked, and the
only DRC warning is the expected `RTSTAT-10` on unused secondary outputs of the
inferred router RAM64M8 primitives.

The complete 61,952-bit weight payload maps to exactly two RAMB36E2 primitives
with no LUTRAM or DSP. Ownership, context checking, counters, and the elastic
replay stage add 109 LUT and 132 FF. All 230 routable nets are fully routed,
all internal endpoints are constrained, and DRC reports zero violations. This
bank is one N8 output tile by one feeder chunk of at most eight input channels;
full-layer channel-chunk accumulation is intentionally not claimed yet.

The resident-weight RS datapath retains the five feeder RAMB36E2, adds the two
weight-bank RAMB36E2, and leaves the 24-DSP compute/postprocess path unchanged.
Relative to the separate complete-RS and weight-bank measurements, the
integrated wrapper adds only 15 CLB LUT and 6 FF. All 7,859 routable nets are
fully routed, every internal register endpoint is constrained, and the only
DRC warning is the expected `RTSTAT-10` on unused secondary outputs of the
router's inferred RAM64M8 primitives. The positive timing margin is measured
at the single 200 MHz target; its difference from the earlier RS result is
placement-dependent rather than an architectural speedup claim.

The 131,072-bit partial-sum payload maps to exactly four RAMB36E2 primitives,
with zero LUTRAM and zero DSP. Eight parallel signed INT32 adders plus ownership
and sequence checking use 791 LUT and 649 FF. All 1,287 routable nets are fully
routed, every internal register endpoint is constrained, and DRC reports zero
violations. One unit covers conv3/conv4/conv5's 13x13 raster (169 words); conv2's
27x27 raster requires two cascaded units. Conv1 has only one input-channel
chunk and does not require cross-chunk accumulation.

The accumulator-aware slice retains exactly the partial-sum bank's four
RAMB36E2, the requant block's eight DSP48E2, and the router's 96 distributed-
RAM LUTs. It uses 3,172 CLB LUT and 1,157 FF. Compared with the sum of scanner,
partial-sum bank, requant, and router measurements, integration adds 183 LUT
while saving 18 FF; the added logic owns chunk/raster ordering, context checks,
and final-emission metadata reconstruction. All 4,283 routable nets are fully
routed, all 6,445 setup/hold endpoints meet the 200 MHz constraint, and the
only DRC warning is the expected `RTSTAT-10` on unused secondary outputs of the
router's inferred RAM64M8 primitives.

The accumulator-aware complete base datapath retains the SA's 16 compute
DSP48E2 and 41 skew SRLs, the output slice's eight requant DSP48E2 and four
RAMB36E2, and the router's 96 distributed-RAM LUTs. It uses 4,511 CLB LUT and
3,329 FF. Cross-module optimization saves 69 LUT and 28 FF versus the sum of
the separate SA and accumulator-aware output-slice measurements. The wrapper's
accepted lane-mask shadow costs only eight FF; no complete parameter copy is
added. All 7,772 routable nets are fully routed, all 16,615 setup/hold endpoints
meet the 200 MHz constraint, and the only DRC warning is the expected
`RTSTAT-10` on unused secondary RAM64M8 outputs.

The resident-weight accumulator RS datapath combines the feeder's five
RAMB36E2, resident-weight bank's two RAMB36E2, and partial-sum bank's four
RAMB36E2 for an exact total of eleven. Its 24 DSP48E2 remain the unchanged 16
packed compute PEs plus eight requant lanes; the 137 non-logic LUTs remain 96
router LUTRAM LUTs plus 41 SA skew SRLs. Relative to the separately measured
accumulator base, feeder, and weight bank, the issue/ownership integration adds
62 CLB LUT and 35 FF. All 9,517 routable nets are fully routed, all 19,018
setup/hold endpoints meet 200 MHz, and the only DRC warning is the expected
`RTSTAT-10` on unused secondary RAM64M8 outputs.

The dual-accumulator resident-weight datapath adds one more four-RAMB36E2
partial-sum segment for an exact total of fifteen: five feeder, two resident
weight, and eight partial-sum RAMB36E2. The compute/postprocess allocation stays
at 24 DSP48E2, and the 137 non-logic LUTs remain 96 router LUTRAM LUTs plus 41
SA skew SRLs. Relative to the measured one-bank resident accumulator path, the
second bank and pair/global-raster control add 1,159 CLB LUT, 573 FF, and four
BRAM36 with no DSP increase. All 11,290 routable nets are fully routed, all
21,080 setup/hold endpoints meet 200 MHz, and the only DRC warning is the
expected `RTSTAT-10` on unused secondary RAM64M8 outputs.

The activation-buffered integration adds the dual-segment owner's four
RAMB36E2 to the existing five feeder, two resident-weight, and eight
partial-sum banks for an exact total of nineteen. The 24 DSP48E2, 96 router
LUTRAM LUTs, and 41 SA skew SRLs are unchanged. Compared with the separate
dual-accumulator RS and dual-segment activation measurements, ordered metadata,
registered command validation, atomic launch, and completion ownership add 245
CLB LUT and 310 FF. All 13,474 routable nets are fully routed, all 24,237
setup/hold endpoints meet 200 MHz, and the only DRC warning is the expected
`RTSTAT-10` on unused secondary RAM64M8 outputs.

The N8 DMA ingress uses 115 LUT and 250 FF with no BRAM, LUTRAM, SRL, or DSP.
The 128-bit beat register is the only payload buffer; storage remains in the
destination owner. All 294 routable nets are fully routed, all 1,066
setup/hold endpoints meet 200 MHz, and DRC reports zero violations. This is the
stream adapter measurement only; AXI DMA IP, interconnect, and the full KV260
shell are measured later at top level.

The DMA-fed integration retains exactly nineteen RAMB36E2 and 24 DSP48E2;
its 137 non-logic LUTs remain the router's 96 LUTRAM LUTs plus the SA's 41
skew SRLs. Integration shares or removes 71 CLB LUT compared with the sum of
the separately measured activation-buffered datapath and DMA ingress, while
the FF count is exactly additive. All 13,815 routable nets are fully routed,
all 25,006 setup/hold endpoints meet 200 MHz, and there are zero unconstrained
internal endpoints. The only DRC warning is the already expected `RTSTAT-10`
on unused secondary outputs of the router's inferred RAM64M8 primitives.

The N8 DMA result egress uses 241 LUT and 369 FF with no BRAM, LUTRAM, SRL, or
DSP. Its two 64-bit word registers are the only payload storage. All 369
routable nets are fully routed, all 1,369 setup/hold endpoints meet 200 MHz,
there are zero unconstrained internal endpoints, and DRC reports zero
violations. This remains an adapter-only measurement; the AXI DMA S2MM IP,
interconnect, DDR path, and software driver are top-level costs.

The full DMA-loop integration retains exactly nineteen RAMB36E2 and 24
DSP48E2; its 137 non-logic LUTs remain the router's 96 LUTRAM LUTs plus the
SA's 41 skew SRLs. Compared with the separately measured DMA-fed compute path
and result egress, direct output ownership, composite errors, and the full-loop
boundary add 133 CLB LUT while saving three FF after cross-module
optimization. All 14,284 routable nets are fully routed, all 26,256 setup/hold
endpoints meet 200 MHz, and there are zero unconstrained internal endpoints.
The only DRC warning is the expected `RTSTAT-10` on unconsumed OOC outputs and
unused secondary RAM64M8 outputs.

The registered DMA chunk scheduler uses 135 LUT and 399 FF with no LUTRAM,
SRL, BRAM, or DSP. The FF cost is the single retained software command and
status counters, including the Conv1 direct-stream selector; there is no
command FIFO or payload storage. All 386 routable nets are fully routed, all
1,551 setup/hold endpoints meet 200 MHz, there are
zero unconstrained internal register endpoints, and DRC reports zero
violations.

The scheduler-controlled full DMA loop retains exactly nineteen RAMB36E2, 24
DSP48E2, 96 distributed-RAM LUTs in the output FIFO, and 41 SA skew SRLs. It
uses 7,775 CLB LUT and 6,440 FF, only 19 LUT and 400 FF more than the manual
full-loop boundary after cross-module optimization. All 14,766 routable nets
are fully routed, all 27,532 setup/hold endpoints meet 200 MHz, and there are
zero unconstrained internal register endpoints. DRC reports only the expected
`RTSTAT-10` warning on unconsumed OOC outputs and unused secondary RAM64M8
outputs.

A simple 2x scaling of the measured base tile would be about 2,816 CLB LUT and
4,400 FF before full-tile placement effects. Therefore M8xN8 expansion remains
gated on the deferred PE/resource pass rather than being committed now.

## Shared Conv/FC compute top

`rtl/integration/alexnet_m4n8_shared_compute_top.sv` now joins the measured
row-stationary Conv command path and the FC6/7/8 layer path around exactly one
common M4xN8 compute/output block. Conv and FC retain separate front-end
feeders and activation/weight banks, while the shared block owns the unchanged
16 packed-MAC DSPs, eight requant DSPs, scanner, 4096-word N8 INT32
partial-sum bank, and result router. This removes the duplicate SA that a
direct composition of the prior standalone wrappers would have created.
The larger bank holds Conv1's complete 55x55 raster (3,025 N8 words), while
the direct activation-stream input bypasses the 1,024-word Conv activation
ping-pong capacity for the 224x224 RGB input (50,176 N8 words).

The top records one Conv/FC owner and changes it only through an explicit
drained release handshake. New work from the inactive path is masked.
Release is rejected while computation, partial sums, result AXIS traffic, an
FC job, or an FC external result commit remains active. The common block is
not reset between clean owners. Shared compute faults remain sticky until
reset; the existing row-stationary command scheduler may still recover its
own rejected/DMA command faults using its established clear protocol.

The combined regression first runs the existing two-channel-chunk Conv2-sized
27x27 numerical/error suite (729 result words and 378 spatial tiles), then
changes ownership without reset and executes a complete FC8 M1 layer: 125 N8
tiles, 625 K chunks, 512,000 K tokens, and all 1,000 class scores compared with
the C++ dense/requant reference. It also retains both FC negative cases.
1,792,298 deliberately early release cycles were blocked, including resident
partial-sum and delayed FC result-commit boundaries. The regression reports
`ALEXNET_M4N8_SHARED_COMPUTE_TOP_TEST_PASSED`.

A separate full-geometry Conv1 regression sends all 50,176 RGB input words
through the direct stream, executes K=363, and numerically checks all 3,025
output words in the 4,096-word accumulator. The scheduler regression also
checks that a streaming command emits no activation DMA descriptor and orders
weight load, 3,025-word result arming, chunk launch, and retirement correctly.

This is a combined compute top, not yet the board top. The new graph sequencer
and Pool5 flatten reader remain standalone and are not connected to it. It has
no connected pool service, physical DDR addresses, AXI-MM/AXI-Lite shell, PS
software, or camera runtime.

The routed 200 MHz OOC top uses 9,063 CLB LUT, 7,721 FF, 42 RAMB36E2, and
exactly 24 DSP48E2. The DSP split remains 16 packed MAC plus eight requant
lanes, confirming one SA rather than two. WNS is +0.017 ns and WHS is
+0.046 ns with zero TNS/THS. All 16,557 routable nets are fully routed, all
31,978 setup/hold endpoints meet timing, and there are no unconstrained
internal endpoints. DRC has `DPOP-3` on one implementation-selected requant
DSP output and `RTSTAT-10` on unconsumed OOC/status outputs; neither is a
routing or timing failure.

## Logical graph and Pool5-to-FC6 boundary

`rtl/control/alexnet_graph_controller.sv` now issues the fixed layer order
Conv1..Conv5 then FC6..FC8, including all convolution geometry, Pool1/2/5
boundaries, Conv1 streaming, and Pool5 flatten flags. It acquires the one
shared compute owner once for Conv and once for FC and validates layer/tag
completion metadata. Its behavioral regression completes five Conv and three
FC jobs in order and separately confirms that mismatched completion metadata
raises and holds the protocol fault. The 200 MHz OOC result is 94 LUT and 38
FF with WNS +2.051 ns, WHS +0.089 ns, no BRAM/DSP, no routing errors, and zero
DRC violations. The standalone result remains preserved; the controller is
also instantiated by the graph-connected compute top described below.

`rtl/feeder/alexnet_pool5_fc6_flatten_reader.sv` gathers Pool5's
`[channel_group][y][x][lane]` N8 storage into PyTorch FC6 channel-major K
order. Its regression checks all 9,216 scalars and 1,152 N8 words across the
actual ten FC6 chunks. The registered two-cycle `/36` setup plus sequential
coordinate walk removes the long live address path; `x36` is forced to
shift/add logic so no compute DSP is consumed. The routed 200 MHz result is
311 LUT, 291 FF, zero BRAM/DSP, WNS +0.843 ns, WHS +0.064 ns, zero routing
errors, and zero DRC violations.

## Graph-connected compute top

`rtl/control/alexnet_conv_layer_controller.sv` fills the missing boundary
between one graph-level Conv job and the shared row-stationary command port.
Across Conv1..Conv5 it emits 144 output N8 tiles and 3,912 commands, preserving
one accumulator context across every tile's input chunks. It requests one
parameter record per output tile and refuses to retire a layer until the
external storage/Pool service acknowledges the complete layer result. Conv1
commands use direct activation streaming; all other commands describe the
activation and weight transfers required by the existing scheduler.

Its regression checks every command's layer geometry, counts, byte lengths,
N base/slice, tags, first/final markers, result ownership, and Pool1/2/5
commit metadata. It reports:

```text
ALEXNET_CONV_LAYER_CONTROLLER_TEST_PASSED layers=5 n8_tiles=144 commands=3912 raw_output_words=60624 metadata_fault=stable
```

`rtl/integration/alexnet_graph_compute_orchestrator.sv` connects this Conv
controller to `alexnet_graph_controller`, the shared-owner handshake, and the
existing FC layer-job port. Its full control regression performs all 3,912
Conv command completions, five layer result commits, three FC jobs, and the
single drained Conv-to-FC transition:

```text
ALEXNET_GRAPH_COMPUTE_ORCHESTRATOR_TEST_PASSED conv_layers=5 conv_tiles=144 conv_commands=3912 conv_commits=5 fc_layers=3 owners=2
```

`rtl/integration/alexnet_m4n8_graph_compute_top.sv` then instantiates that
orchestrator around the real `alexnet_m4n8_shared_compute_top`. The complete
hierarchy elaborates and routes at the sole 200 MHz target with exactly one
M4xN8 SA and 24 DSP48E2. The routed result is 8,878 CLB LUT, 7,355 FF, 42
RAMB36E2, WNS +0.008 ns, WHS +0.031 ns, and zero TNS/THS. All 16,124 routable
nets are fully routed across 30,574 setup/hold endpoints. DRC reports only
`RTSTAT-10` for unused OOC/status loads.

The graph-compute top connects graph sequencing to the real shared compute
hierarchy, but the full 3,912-command test uses abstract command completions;
it is not a full trained-weight numerical AlexNet run. The connected data-plane
top below supersedes its previously external pooling and FC6-flatten services.

## Connected Conv/FC data plane and graph-data top

`rtl/integration/alexnet_conv_fc_data_service.sv` now connects raw Conv output
to one reused Pool1/2/5 max-pool engine (Conv3/4 bypass it), repacks the stored
N8 stream, caches Pool5 locally, and injects its channel-major flatten order
into FC6 activation requests. The Pool5 cache uses a lossless 128-to-144-bit
gearbox and one 512x144 memory, so its exact 73,728-bit payload maps to two
RAMB36E2 rather than four depth/width-rounded blocks. Conv5-to-Pool5-to-FC6
integration checks 5,408 raw N8 words, 1,152 pooled words, all 9,216 FC6
scalars, and ten chunks with randomized stalls.

The standalone data service routes at 200 MHz with 2,049 LUT, 1,546 FF, three
RAMB36E2 (one pool plus two Pool5 cache), zero DSP, WNS +0.348 ns, and WHS
+0.055 ns. `rtl/control/alexnet_ddr_address_planner.sv` separately validates
all 21,893 fixed AlexNet descriptor cases, covers the exact 61,090,496-byte
weight and 165,504-byte parameter blobs, rejects external Conv1 activation and
FC6 flatten requests, and routes with 921 LUT, 344 FF, zero BRAM/DSP, WNS
+0.372 ns, and WHS +0.055 ns.

`rtl/integration/alexnet_m4n8_graph_data_top.sv` is the first single hierarchy
that joins graph control, the real shared compute block, pooling/bypass,
external stored-result streaming, the two-BRAM Pool5 cache, and automatic FC6
flatten injection. The Conv controller now arms the result service before its
first compute command; this removes the real-stream deadlock that would occur
if the sink were configured after all commands. A completion arriving beside
the final command is latched until layer retirement. Both the 3,912-command
Conv regression and graph-owner regression pass again with this ordering.

The routed graph-data top uses exactly one M4xN8 SA, 10,938 CLB LUT, 8,899 FF,
45 RAMB36E2, and 24 DSP48E2. WNS/WHS are +0.098/+0.046 ns at the only 200 MHz
target, with zero TNS/THS and all 19,330 routable nets connected. The 24 DSPs
remain 16 packed MAC plus eight requant lanes; PE and SA RTL were not changed.
Expected OOC warnings are two implementation-selected `DPOP-3` requant DSP
pipeline warnings and one `RTSTAT-10` for deliberately exported status ports.

## Physical DMA and software-control top

`rtl/integration/alexnet_graph_dma_descriptor_bridge.sv` now arbitrates Conv
and FC activation, weight, parameter, and result requests through the physical
DDR address planner. Its registered request boundary removes the six-owner
arbitration path from the planner's shift/add address path. Commands are held
until the single AXI DMA control master accepts them, and completion metadata is
returned to the originating controller. The current bridge is included in the
fully routed graph-DMA and accelerator-IP results below.

Parameter MM2S payloads are diverted by
`rtl/integration/alexnet_graph_dma_read_router.sv` into
`rtl/dma/alexnet_parameter_record_loader.sv`. The loader validates the frozen
little-endian `<iiBB6x>` records and presents eight channel records as one
backpressured N8 parameter tile. Its routed result is 50 LUT, 588 FF, WNS
+1.942 ns, WHS +0.109 ns, and no BRAM/DSP. The read-router regression checks
normal graph payloads, parameter diversion, byte/TLAST accounting, and S2MM
ownership.

Raw Conv outputs cannot be written directly because Pool1, Pool2, and Pool5
change the stored raster size. `alexnet_conv_storage_dma_scheduler` therefore
splits each aggregate post-pool layer stream into physical N8-tile S2MM
descriptors. Its exhaustive regression covers all five layers, 144 descriptors,
and 24,560 stored N8 words. Conv retirement now waits for both the local
pool/bypass drain and the final physical storage completion.

`rtl/integration/alexnet_m4n8_graph_dma_top.sv` joins these services with the
existing graph-data hierarchy and one `axi_dma_simple_master`. Both AXI DMA
channels require DRE because FC8 emits valid 8-byte descriptors. The full
200 MHz protocol regression accepts 8-byte-aligned MM2S/S2MM commands for
AlexNet while preserving the shared module's 16-byte LeNet default. The full
physical-DMA accelerator hierarchy routes at the only 200 MHz target with
12,266 CLB LUT, 9,946 FF, exactly 45 RAMB36E2, and exactly 24 DSP48E2.
WNS/WHS are +0.088/+0.046 ns, TNS/THS are zero, and all 21,883 routable nets
are connected.

`rtl/control/alexnet_axi_lite_regs.sv` adds a 32-bit PS register interface,
one pending job, atomic configuration snapshots, sticky completion/error
status, progress counters, and interrupt control. Its unit regression covers
independent AW/W ordering, response backpressure, byte strobes, pending/active
configuration isolation, queue rejection, configuration rejection, W1C status,
and interrupt behavior. The map is frozen in `CONTROL_REGISTERS.md` and mirrored
by `software/include/alexnet_accelerator_regs.h`.

`rtl/integration/alexnet_m4n8_accelerator_top.sv` is now the reusable PL IP
boundary. It exposes PS control AXI-Lite, a 64-bit preprocessed-camera AXIS,
128-bit AXI DMA MM2S/S2MM payload ports, the AXI DMA register master, and IRQ.
The complete control-plus-accelerator top routes at 200 MHz with 12,730 CLB LUT,
11,503 FF, 45 RAMB36E2, and 24 DSP48E2. WNS/WHS are +0.021/+0.036 ns,
TNS/THS are zero, and all 23,821 routable nets are connected. The only DRC
entry is the expected OOC `RTSTAT-10` warning on exported interface/status
loads. PE and SA RTL remain unchanged.

## KV260 board top, camera runtime, and frame-replay optimization

`stages/01_kv260_m4n8` is the complete KV260 hardware build stage. It packages
the accelerator and camera adapter IPs, uses the KV260 ZynqMP board preset,
connects one DRE-enabled 128-bit main MM2S/S2MM DMA and one PS-owned 64-bit
camera MM2S DMA to DDR HP0, and places control, streams, reset, and interrupts
in one nominal 200 MHz domain. The PS address map is accelerator
`0xA0000000`, main DMA `0xA0010000`, and camera DMA `0xA0020000`.

The camera adapter accepts exactly 50,176 eight-byte DDR words for one
`224x224` preprocessed RGB image. It keeps the three signed INT8 channel bytes,
zeros five padding lanes, outputs N8 `TKEEP=0x07`, and latches an error for a
bad input keep mask or incorrect `TLAST` position. Its stall and malformed-
frame regression prints `ALEXNET_CAMERA_RGBX_AXIS_ADAPTER_SIM_PASS`.

`rtl/integration/alexnet_camera_frame_replay.sv` now captures that frame once
in 13 URAM288 blocks and replays it eight times for Conv1's eight N8 output
tiles. The previous runtime launched and waited for the 401,408-byte camera DMA
eight times per inference; the optimized runtime launches it once. This removes
seven DMA launches/waits and 2,809,856 repeated DDR bytes per image while
leaving the M4xN8 PE/SA and 200 MHz clock unchanged. Its elastic two-stage
read/output pipeline sustains one word per cycle under backpressure. The
capture/replay regression checks exact frame length, lane mask, `TLAST`, eight
replays, stalls, malformed input, and frame replacement, and prints
`ALEXNET_CAMERA_FRAME_REPLAY_SIM_PASS`.

The first full-board attempt exposed the critical partial-sum BRAM
read-add-write path and failed setup timing. One explicit read pipeline stage
was added to `rtl/memory/alexnet_n8_int32_partial_sum_bank.sv`; PE and SA RTL
were not changed. The partial-sum bank, accumulator output slice, FC layer
datapath, and scheduled Conv DMA datapath regressions all passed again, and the
partial-sum bank OOC WNS improved to +1.123 ns at 200 MHz.

The board-valid clock/reset correction takes stock PS PL0 at 99.999001 MHz,
generates the 199.998002 MHz fabric clock with one MMCM, releases fabric reset
only after MMCM lock, and holds both active-low reset inputs inactive. The
corrected `224x224` full-board build completed synthesis, implementation,
bitstream generation, and bitstream-bearing XSA export. Before the frame cache
was added, the physical KV260 completed trained Conv1..FC8 inference from both
a saved dog image and an ABKO USB-camera frame. The live path printed a dog
ImageNet result in the terminal. Measured end-to-end camera latency was 504.9
ms, or 1.9806 frame/s, 1.4145 GMAC/s, and 2.829 GOPS (0.002829 TOPS). This is
the functional baseline for the optimization, not the optimized result.

The new frame-cache release completed the full board build with
`Performance_ExplorePostRoutePhysOpt` without changing PE or SA RTL. Final
timing is WNS/WHS +0.035/+0.010 ns with zero TNS/THS across 84,721 constrained
setup/hold endpoints. All 46,063 routable nets are fully routed. Utilization is
21,390 CLB LUT (18.26%), 22,844 registers (9.75%), 52 block RAM tiles (36.11%),
13 URAM (20.31%), one MMCM, and 24 DSP48E2 (1.92%). DRC has zero errors and
zero critical warnings; the 25 remaining warnings are device/IP advisories
recorded in the stage README.

Vectorless power is 3.020 W, so the unchanged arithmetic peak is 0.0128 TOPS
and 0.00424 peak TOPS/W. The optimization targets effective throughput and
energy per classified image by removing redundant DDR work; it does not claim
a larger compute peak.

The optimized firmware was loaded on the KV260 and completed 15 consecutive
USB-camera classifications. Mean/min/max PL round-trip latency was
502.227/501.8/502.8 ms, corresponding to 1.9911 frame/s, 1.4220 GMAC/s, and
2.8441 GOPS (0.002844 TOPS). Relative to the 504.9 ms baseline, latency fell
2.673 ms (0.529%) and throughput rose 0.532%. Forty 200 ms board-power samples
during continuous inference averaged 3.7895 W (3.64..4.42 W), giving 0.0007505
effective TOPS/W and 1.9032 J per inference for the complete board. A subsequent
one-shot inference after interrupting the continuous loop also completed in
502.5 ms. PE optimization and the one M8xN8 expansion remain later steps; all
implementation experiments stay at 200 MHz.
