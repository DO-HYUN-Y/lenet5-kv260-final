# Stage 06 — Persistent KV260 Runtime

This stage preserves the signed-off Stage05 bitstream, RTL, address map,
driver ABI, DMA allocation, quantization, and polling scheduler. It changes
only the PS userspace execution path.

## Runtime contract

- Open `/dev/lenet5_board` once.
- Map the coherent 128 KiB DMA buffer once.
- Map the test images, labels, and Python golden logits once.
- Copy weights and parameters into the DMA buffer once.
- Program invariant weight/parameter/input/result addresses and timeout once.
- Submit one model-reload job followed by resident-model jobs.
- Copy only the next 1,024-byte input for each resident job.
- Check accelerator ID, scheduler status/error, DMA errors, completed count,
  completed job ID, timeout, and all ten INT8 logits for every job.
- Use polling. A ring queue, interrupt path, or compute/DMA overlap is not
  claimed by this stage.

The DMA mapping comes from `dma_alloc_coherent`; no userspace cache
flush/invalidate operation is required for this mapping.

## Baseline

Stage04's deliberately simple per-image runtime:

```text
images=10000
logit_bytes_exact=100000/100000
wall_seconds=1.557014
wall_images_per_second=6422.549
hardware_wait_seconds=0.881830
cycle_limited_images_per_second=11727.309
```

## Commands

```bash
stages/06_persistent_runtime/scripts/deploy.sh
stages/06_persistent_runtime/scripts/run_board.sh 100
stages/06_persistent_runtime/scripts/run_board.sh 10000
```

Neither script programs PL or loads/unloads the kernel module.

## Verification status

```text
LOCAL_BUILD:             PASS
BOARD_100_BYTE_EXACT:    PASS
BOARD_10000_BYTE_EXACT:  PASS
PERFORMANCE_COMPARE:     PASS
```

## Board results

```text
images                         = 10000
logit bytes exact              = 100000/100000
accuracy                       = 98.93% (9893/10000)
wall seconds                   = 1.060246
wall images/s                  = 9431.773
hardware job seconds           = 0.852693
PL job busy                    = 80.424%
job cycles avg/min/max         = 12790.262 / 12783 / 19214
DMA cycles avg/min/max         = 861.262 / 854 / 7285
prepare us/image               = 1.343
control us/image               = 5.113
submit/poll wait us/image      = 87.587
verify us/image                = 11.573
timeout/DMA/scheduler/mismatch = 0
```

Compared with the Stage04 validation runtime:

```text
throughput gain       = 46.854%
wall-time reduction   = 31.905%
PL job busy           = 54.765% -> 80.424%
gap to cycle limit    = 19.574%
```

The remaining software cost is dominated by per-job control and exhaustive
post-job verification ioctls. The next throughput step is a versioned
submit/wait ioctl or descriptor queue that combines register operations while
preserving timeout/error/job-ID checks. Per-job interrupts are not the first
choice for an approximately 85 us job because interrupt wake-up overhead may
exceed the current polling overhead. Wider MAC RTL is also not the next step:
the resident hardware job already spends about 93% of its cycles core-busy.
