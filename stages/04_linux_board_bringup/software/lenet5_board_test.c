// SPDX-License-Identifier: MIT
#define _POSIX_C_SOURCE 200809L

/*
 * Deterministic Stage04 board test.
 *
 * The first mode reads only ID/status registers. The inference mode loads the
 * packed model and one fixed-scale MNIST image into the coherent DMA buffer,
 * submits one autonomous job, and compares all ten INT8 logits.
 */

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include "../driver/lenet5_board_uapi.h"

#define DEVICE_PATH "/dev/lenet5_board"

#define EXPECTED_ID 0x00024c35u
#define EXPECTED_CLOCK_HZ 149998501u
#define CLOCK_TOLERANCE_HZ 5000u
#define CLOCK_MIN_HZ 149000000u
#define CLOCK_MAX_HZ 151000000u
#define INPUT_CLOCK_MIN_HZ 90000000u
#define INPUT_CLOCK_MAX_HZ 110000000u

#define REG_ID                   0x00u
#define REG_CTRL                 0x04u
#define REG_STATUS               0x08u
#define REG_BUSY_CYCLES          0x20u
#define REG_COMPUTE_CYCLES       0x24u
#define REG_POOL_CYCLES          0x28u
#define REG_PARAM_CYCLES         0x2cu
#define REG_AUTO_CFG             0x30u
#define REG_AUTO_WEIGHT_ADDR     0x34u
#define REG_AUTO_PARAM_ADDR      0x38u
#define REG_AUTO_INPUT_ADDR      0x3cu
#define REG_AUTO_RESULT_ADDR     0x40u
#define REG_AUTO_TIMEOUT         0x44u
#define REG_AUTO_JOB_ID          0x48u
#define REG_AUTO_STATUS          0x4cu
#define REG_AUTO_ERROR           0x50u
#define REG_AUTO_COMPLETED_JOB   0x54u
#define REG_AUTO_JOB_CYCLES      0x58u
#define REG_AUTO_DMA_CYCLES      0x5cu
#define REG_AUTO_COMPLETED_COUNT 0x60u

#define DMA_MM2S_STATUS 0x04u
#define DMA_S2MM_STATUS 0x34u
#define DMA_ERROR_MASK  0x00000070u

#define CTRL_CLEAR       (1u << 3)
#define CTRL_AUTO_SUBMIT (1u << 4)

#define AUTO_BUSY         (1u << 0)
#define AUTO_DONE         (1u << 1)
#define AUTO_ERROR        (1u << 2)
#define AUTO_SUBMIT_READY (1u << 4)

#define WEIGHT_OFFSET 0x00000u
#define WEIGHT_BYTES  92736u
#define PARAM_OFFSET  0x16a40u
#define PARAM_BYTES   1888u
#define INPUT_OFFSET  0x171a0u
#define INPUT_BYTES   1024u
#define RESULT_OFFSET 0x175a0u
#define RESULT_BYTES  10u
#define USED_BYTES    0x175b0u
#define EXPECTED_HW_CORRECT_10000 9893u

static const int8_t first_expected[RESULT_BYTES] = {
    -30, -9, -8, -6, -9, -25, -57, 38, -33, 5
};

struct job_metrics {
    uint32_t job_cycles;
    uint32_t dma_cycles;
    double host_seconds;
    int predicted;
    bool saw_busy;
};

static uint32_t reg_read(int fd, uint32_t space, uint32_t offset)
{
    struct lenet5_reg_access access = {
        .space = space,
        .offset = offset,
    };

    if (ioctl(fd, LENET5_IOC_READ_REG, &access) < 0) {
        fprintf(stderr, "FAIL: read space=%u offset=%#x: %s\n",
                space, offset, strerror(errno));
        exit(EXIT_FAILURE);
    }
    return access.value;
}

static void reg_write(int fd, uint32_t space, uint32_t offset,
                      uint32_t value)
{
    struct lenet5_reg_access access = {
        .space = space,
        .offset = offset,
        .value = value,
    };

    if (ioctl(fd, LENET5_IOC_WRITE_REG, &access) < 0) {
        fprintf(stderr, "FAIL: write space=%u offset=%#x: %s\n",
                space, offset, strerror(errno));
        exit(EXIT_FAILURE);
    }
}

static void load_exact(const char *path, void *destination, size_t size,
                       off_t offset)
{
    uint8_t *out = destination;
    size_t done = 0;
    int fd = open(path, O_RDONLY);

    if (fd < 0) {
        fprintf(stderr, "FAIL: open %s: %s\n", path, strerror(errno));
        exit(EXIT_FAILURE);
    }
    while (done < size) {
        ssize_t count = pread(fd, out + done, size - done, offset + done);
        if (count < 0) {
            fprintf(stderr, "FAIL: read %s: %s\n", path, strerror(errno));
            close(fd);
            exit(EXIT_FAILURE);
        }
        if (count == 0) {
            fprintf(stderr, "FAIL: %s is shorter than required\n", path);
            close(fd);
            exit(EXIT_FAILURE);
        }
        done += (size_t)count;
    }
    close(fd);
}

static double monotonic_seconds(void)
{
    struct timespec ts;

    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        perror("clock_gettime");
        exit(EXIT_FAILURE);
    }
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}

static int id_only(int fd, const struct lenet5_board_info *info)
{
    uint32_t id = reg_read(fd, LENET5_REG_SPACE_ACCEL, REG_ID);
    uint32_t status = reg_read(fd, LENET5_REG_SPACE_ACCEL, REG_STATUS);
    uint32_t auto_status =
        reg_read(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_STATUS);
    uint32_t mm2s =
        reg_read(fd, LENET5_REG_SPACE_DMA, DMA_MM2S_STATUS);
    uint32_t s2mm =
        reg_read(fd, LENET5_REG_SPACE_DMA, DMA_S2MM_STATUS);

    printf("PL_CLOCK_HZ=%u\n", info->pl_clock_hz);
    printf("PL_INPUT_CLOCK_HZ=%u\n", info->pl_input_clock_hz);
    printf("DMA_ADDR=%#" PRIx64 " DMA_SIZE=%" PRIu64 "\n",
           (uint64_t)info->dma_addr, (uint64_t)info->dma_size);
    printf("ACCEL_ID=%#010x STATUS=%#010x AUTO_STATUS=%#010x\n",
           id, status, auto_status);
    printf("DMA_MM2S_STATUS=%#010x DMA_S2MM_STATUS=%#010x\n",
           mm2s, s2mm);

    if (info->pl_clock_hz < CLOCK_MIN_HZ ||
        info->pl_clock_hz > CLOCK_MAX_HZ) {
        fprintf(stderr, "FAIL: PL clock is outside safe range\n");
        return EXIT_FAILURE;
    }
    if (info->pl_input_clock_hz < INPUT_CLOCK_MIN_HZ ||
        info->pl_input_clock_hz > INPUT_CLOCK_MAX_HZ) {
        fprintf(stderr, "FAIL: PL0 input clock is outside safe range\n");
        return EXIT_FAILURE;
    }
    if (info->pl_clock_hz < EXPECTED_CLOCK_HZ - CLOCK_TOLERANCE_HZ ||
        info->pl_clock_hz > EXPECTED_CLOCK_HZ + CLOCK_TOLERANCE_HZ) {
        fprintf(stderr, "FAIL: PL fabric clock does not match Stage05\n");
        return EXIT_FAILURE;
    }
    if (id != EXPECTED_ID) {
        fprintf(stderr, "FAIL: accelerator ID mismatch\n");
        return EXIT_FAILURE;
    }
    if ((mm2s | s2mm) & DMA_ERROR_MASK) {
        fprintf(stderr, "FAIL: AXI DMA reports an error\n");
        return EXIT_FAILURE;
    }
    printf("LENET5_ID_TEST_PASS\n");
    return EXIT_SUCCESS;
}

static int run_image(int fd, const struct lenet5_board_info *info,
                     const char *weight_path,
                     const char *param_path,
                     const char *image_path,
                     unsigned long image_index,
                     bool reload_model,
                     uint32_t job_id,
                     const int8_t *expected_logits,
                     bool require_busy,
                     bool verbose,
                     struct job_metrics *metrics)
{
    uint8_t *buffer;
    uint64_t base = info->dma_addr;
    uint32_t auto_status;
    uint32_t completed_before;
    uint32_t completed_after;
    uint32_t error_code;
    uint32_t mm2s;
    uint32_t s2mm;
    uint32_t completed_job;
    uint32_t job_cycles;
    uint32_t dma_cycles;
    uint32_t busy_cycles;
    uint32_t compute_cycles;
    uint32_t pool_cycles;
    uint32_t param_cycles;
    double start_time;
    double end_time;
    bool saw_busy = false;
    bool mismatch = false;
    bool logit_mismatch = false;
    int predicted = 0;

    if (info->dma_size < USED_BYTES || base + USED_BYTES > UINT32_MAX) {
        fprintf(stderr, "FAIL: DMA buffer does not fit the RTL 32-bit address contract\n");
        return EXIT_FAILURE;
    }

    buffer = mmap(NULL, info->dma_size, PROT_READ | PROT_WRITE,
                  MAP_SHARED, fd, 0);
    if (buffer == MAP_FAILED) {
        fprintf(stderr, "FAIL: mmap coherent buffer: %s\n", strerror(errno));
        return EXIT_FAILURE;
    }

    if (reload_model) {
        load_exact(weight_path, buffer + WEIGHT_OFFSET, WEIGHT_BYTES, 0);
        load_exact(param_path, buffer + PARAM_OFFSET, PARAM_BYTES, 0);
    }
    load_exact(image_path, buffer + INPUT_OFFSET, INPUT_BYTES,
               (off_t)image_index * INPUT_BYTES);
    memset(buffer + RESULT_OFFSET, 0xa5, 16);
    __sync_synchronize();

    if (reg_read(fd, LENET5_REG_SPACE_ACCEL, REG_ID) != EXPECTED_ID) {
        fprintf(stderr, "FAIL: accelerator ID mismatch before submit\n");
        munmap(buffer, info->dma_size);
        return EXIT_FAILURE;
    }

    reg_write(fd, LENET5_REG_SPACE_ACCEL, REG_CTRL, CTRL_CLEAR);
    auto_status =
        reg_read(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_STATUS);
    if (!(auto_status & AUTO_SUBMIT_READY)) {
        fprintf(stderr, "FAIL: scheduler is not ready: status=%#x\n",
                auto_status);
        munmap(buffer, info->dma_size);
        return EXIT_FAILURE;
    }

    completed_before =
        reg_read(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_COMPLETED_COUNT);

    reg_write(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_CFG,
              reload_model ? 1u : 0u);
    reg_write(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_WEIGHT_ADDR,
              (uint32_t)(base + WEIGHT_OFFSET));
    reg_write(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_PARAM_ADDR,
              (uint32_t)(base + PARAM_OFFSET));
    reg_write(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_INPUT_ADDR,
              (uint32_t)(base + INPUT_OFFSET));
    reg_write(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_RESULT_ADDR,
              (uint32_t)(base + RESULT_OFFSET));
    reg_write(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_TIMEOUT, 100000000u);
    reg_write(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_JOB_ID, job_id);
    __sync_synchronize();

    start_time = monotonic_seconds();
    reg_write(fd, LENET5_REG_SPACE_ACCEL, REG_CTRL, CTRL_AUTO_SUBMIT);

    for (;;) {
        auto_status =
            reg_read(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_STATUS);
        if (auto_status & AUTO_BUSY)
            saw_busy = true;
        if (auto_status & AUTO_ERROR)
            break;
        if (auto_status & AUTO_DONE)
            break;
        if (monotonic_seconds() - start_time > 5.0) {
            fprintf(stderr, "FAIL: timeout waiting for autonomous done\n");
            munmap(buffer, info->dma_size);
            return EXIT_FAILURE;
        }
    }
    end_time = monotonic_seconds();
    __sync_synchronize();

    error_code =
        reg_read(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_ERROR);
    completed_after =
        reg_read(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_COMPLETED_COUNT);
    mm2s = reg_read(fd, LENET5_REG_SPACE_DMA, DMA_MM2S_STATUS);
    s2mm = reg_read(fd, LENET5_REG_SPACE_DMA, DMA_S2MM_STATUS);
    completed_job =
        reg_read(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_COMPLETED_JOB);
    job_cycles =
        reg_read(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_JOB_CYCLES);
    dma_cycles =
        reg_read(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_DMA_CYCLES);
    busy_cycles = reg_read(fd, LENET5_REG_SPACE_ACCEL, REG_BUSY_CYCLES);
    compute_cycles =
        reg_read(fd, LENET5_REG_SPACE_ACCEL, REG_COMPUTE_CYCLES);
    pool_cycles = reg_read(fd, LENET5_REG_SPACE_ACCEL, REG_POOL_CYCLES);
    param_cycles = reg_read(fd, LENET5_REG_SPACE_ACCEL, REG_PARAM_CYCLES);

    if (metrics) {
        metrics->job_cycles = job_cycles;
        metrics->dma_cycles = dma_cycles;
        metrics->host_seconds = end_time - start_time;
        metrics->saw_busy = saw_busy;
    }

    if (verbose) {
        printf("AUTO_STATUS=%#010x AUTO_ERROR=%#010x SAW_BUSY=%u\n",
               auto_status, error_code, saw_busy ? 1u : 0u);
        printf("DMA_MM2S_STATUS=%#010x DMA_S2MM_STATUS=%#010x\n",
               mm2s, s2mm);
        printf("JOB_ID=%u COMPLETED_COUNT=%u->%u\n",
               completed_job, completed_before, completed_after);
        printf("JOB_CYCLES=%u DMA_CYCLES=%u HOST_SECONDS=%.9f\n",
               job_cycles, dma_cycles, end_time - start_time);
        printf("CORE_BUSY_CYCLES=%u COMPUTE_CYCLES=%u POOL_CYCLES=%u PARAM_CYCLES=%u\n",
               busy_cycles, compute_cycles, pool_cycles, param_cycles);
        printf("LOGITS=");
    }
    for (size_t i = 0; i < RESULT_BYTES; ++i) {
        int8_t value = (int8_t)buffer[RESULT_OFFSET + i];
        if (verbose)
            printf("%s%d", i ? "," : "", value);
        if ((int8_t)buffer[RESULT_OFFSET + predicted] < value)
            predicted = (int)i;
        if (expected_logits && value != expected_logits[i]) {
            mismatch = true;
            logit_mismatch = true;
        }
    }
    if (metrics)
        metrics->predicted = predicted;
    if (verbose)
        printf(" PREDICTED=%d\n", predicted);

    if (!saw_busy && require_busy) {
        fprintf(stderr, "FAIL: busy was not observed\n");
        mismatch = true;
    }
    if (!(auto_status & AUTO_DONE) || (auto_status & AUTO_ERROR) ||
        error_code != 0) {
        fprintf(stderr, "FAIL: scheduler completion/error status\n");
        mismatch = true;
    }
    if ((mm2s | s2mm) & DMA_ERROR_MASK) {
        fprintf(stderr, "FAIL: AXI DMA error bits are set\n");
        mismatch = true;
    }
    if (completed_after != completed_before + 1u) {
        fprintf(stderr, "FAIL: completed count did not increment once\n");
        mismatch = true;
    }
    if (logit_mismatch) {
        fprintf(stderr, "FAIL: logit mismatch image=%lu expected=", image_index);
        for (size_t i = 0; i < RESULT_BYTES; ++i)
            fprintf(stderr, "%s%d", i ? "," : "", expected_logits[i]);
        fprintf(stderr, " actual=");
        for (size_t i = 0; i < RESULT_BYTES; ++i)
            fprintf(stderr, "%s%d", i ? "," : "",
                    (int8_t)buffer[RESULT_OFFSET + i]);
        fprintf(stderr, "\n");
    }

    munmap(buffer, info->dma_size);

    if (mismatch) {
        fprintf(stderr, "FAIL: image test index=%lu\n", image_index);
        return EXIT_FAILURE;
    }

    if (verbose) {
        if (image_index == 0)
            printf("LENET5_FIRST_IMAGE_PASS\n");
        else
            printf("LENET5_IMAGE_RUN_PASS index=%lu\n", image_index);
    }
    return EXIT_SUCCESS;
}

static int run_resident_stress(int fd,
                               const struct lenet5_board_info *info,
                               const char *weight_path,
                               const char *param_path,
                               const char *image_path,
                               unsigned long resident_count)
{
    struct job_metrics current;
    struct job_metrics reload;
    uint64_t resident_job_sum = 0;
    uint64_t resident_dma_sum = 0;
    uint32_t resident_job_min = UINT32_MAX;
    uint32_t resident_job_max = 0;
    uint32_t resident_dma_min = UINT32_MAX;
    uint32_t resident_dma_max = 0;
    unsigned long busy_samples_missed = 0;
    double resident_host_sum = 0.0;
    int result;

    result = run_image(fd, info, weight_path, param_path, image_path, 0,
                       true, 1u, first_expected, false, false, &reload);
    if (result != EXIT_SUCCESS) {
        fprintf(stderr, "FAIL: model-reload stress job\n");
        return result;
    }

    for (unsigned long i = 0; i < resident_count; ++i) {
        result = run_image(fd, info, weight_path, param_path, image_path, 0,
                           false, (uint32_t)(i + 2ul), first_expected,
                           false, false, &current);
        if (result != EXIT_SUCCESS) {
            fprintf(stderr, "FAIL: resident stress job index=%lu\n", i);
            return result;
        }
        resident_job_sum += current.job_cycles;
        resident_dma_sum += current.dma_cycles;
        resident_host_sum += current.host_seconds;
        if (!current.saw_busy)
            busy_samples_missed++;
        if (current.job_cycles < resident_job_min)
            resident_job_min = current.job_cycles;
        if (current.job_cycles > resident_job_max)
            resident_job_max = current.job_cycles;
        if (current.dma_cycles < resident_dma_min)
            resident_dma_min = current.dma_cycles;
        if (current.dma_cycles > resident_dma_max)
            resident_dma_max = current.dma_cycles;
    }

    if (resident_dma_max >= reload.dma_cycles) {
        fprintf(stderr,
                "FAIL: resident jobs did not reduce DMA cycles: reload=%u resident_max=%u\n",
                reload.dma_cycles, resident_dma_max);
        return EXIT_FAILURE;
    }

    printf("RELOAD_JOB_CYCLES=%u RELOAD_DMA_CYCLES=%u RELOAD_HOST_SECONDS=%.9f\n",
           reload.job_cycles, reload.dma_cycles, reload.host_seconds);
    printf("RESIDENT_COUNT=%lu JOB_CYCLES_AVG=%.3f MIN=%u MAX=%u\n",
           resident_count,
           (double)resident_job_sum / (double)resident_count,
           resident_job_min, resident_job_max);
    printf("RESIDENT_DMA_CYCLES_AVG=%.3f MIN=%u MAX=%u HOST_SECONDS_AVG=%.9f\n",
           (double)resident_dma_sum / (double)resident_count,
           resident_dma_min, resident_dma_max,
           resident_host_sum / (double)resident_count);
    printf("RESIDENT_BUSY_SAMPLES_MISSED=%lu\n", busy_samples_missed);
    printf("LENET5_RESIDENT_STRESS_PASS total_jobs=%lu\n",
           resident_count + 1ul);
    return EXIT_SUCCESS;
}

static int run_dataset(int fd, const struct lenet5_board_info *info,
                       const char *weight_path,
                       const char *param_path,
                       const char *image_path,
                       const char *label_path,
                       const char *golden_path,
                       unsigned long image_count)
{
    uint8_t *labels = malloc(image_count);
    int8_t *golden = malloc(image_count * RESULT_BYTES);
    struct job_metrics current;
    uint64_t job_sum = 0;
    uint64_t dma_sum = 0;
    uint32_t job_min = UINT32_MAX;
    uint32_t job_max = 0;
    uint32_t dma_min = UINT32_MAX;
    uint32_t dma_max = 0;
    unsigned long correct = 0;
    unsigned long busy_samples_missed = 0;
    double hardware_host_sum = 0.0;
    double wall_start;
    double wall_end;
    int result;

    if (!labels || !golden) {
        fprintf(stderr, "FAIL: allocate dataset golden buffers\n");
        free(labels);
        free(golden);
        return EXIT_FAILURE;
    }
    load_exact(label_path, labels, image_count, 0);
    load_exact(golden_path, golden, image_count * RESULT_BYTES, 0);

    wall_start = monotonic_seconds();
    for (unsigned long i = 0; i < image_count; ++i) {
        result = run_image(fd, info, weight_path, param_path, image_path, i,
                           i == 0, (uint32_t)(i + 1ul),
                           golden + i * RESULT_BYTES,
                           false, false, &current);
        if (result != EXIT_SUCCESS) {
            fprintf(stderr, "FAIL: dataset image=%lu label=%u\n",
                    i, labels[i]);
            free(labels);
            free(golden);
            return result;
        }
        if ((uint8_t)current.predicted == labels[i])
            correct++;
        job_sum += current.job_cycles;
        dma_sum += current.dma_cycles;
        hardware_host_sum += current.host_seconds;
        if (!current.saw_busy)
            busy_samples_missed++;
        if (current.job_cycles < job_min)
            job_min = current.job_cycles;
        if (current.job_cycles > job_max)
            job_max = current.job_cycles;
        if (current.dma_cycles < dma_min)
            dma_min = current.dma_cycles;
        if (current.dma_cycles > dma_max)
            dma_max = current.dma_cycles;
        if ((i + 1ul) % 1000ul == 0 || i + 1ul == image_count) {
            printf("DATASET_PROGRESS=%lu/%lu CORRECT=%lu\n",
                   i + 1ul, image_count, correct);
            fflush(stdout);
        }
    }
    wall_end = monotonic_seconds();

    printf("DATASET_BYTE_EXACT_IMAGES=%lu\n", image_count);
    printf("DATASET_ACCURACY=%.4f%% CORRECT=%lu/%lu\n",
           100.0 * (double)correct / (double)image_count,
           correct, image_count);
    printf("DATASET_JOB_CYCLES_AVG=%.3f MIN=%u MAX=%u\n",
           (double)job_sum / (double)image_count, job_min, job_max);
    printf("DATASET_DMA_CYCLES_AVG=%.3f MIN=%u MAX=%u\n",
           (double)dma_sum / (double)image_count, dma_min, dma_max);
    printf("DATASET_HW_WAIT_SECONDS=%.6f WALL_SECONDS=%.6f IMAGES_PER_SECOND=%.3f\n",
           hardware_host_sum, wall_end - wall_start,
           (double)image_count / (wall_end - wall_start));
    printf("DATASET_BUSY_SAMPLES_MISSED=%lu\n", busy_samples_missed);

    free(labels);
    free(golden);

    if (image_count == 10000ul &&
        correct != EXPECTED_HW_CORRECT_10000) {
        fprintf(stderr,
                "FAIL: 10000-image accuracy mismatch expected=%u actual=%lu\n",
                EXPECTED_HW_CORRECT_10000, correct);
        return EXIT_FAILURE;
    }
    printf("LENET5_DATASET_BYTE_EXACT_PASS images=%lu\n", image_count);
    return EXIT_SUCCESS;
}

static void usage(const char *program)
{
    fprintf(stderr,
            "Usage:\n"
            "  %s --id-only\n"
            "  %s --read-one <accel|dma> OFFSET\n"
            "  %s --stress-resident COUNT WEIGHTS PARAMS TEST_IMAGES\n"
            "  %s --dataset COUNT WEIGHTS PARAMS TEST_IMAGES LABELS GOLDEN_LOGITS\n"
            "  %s WEIGHTS PARAMS TEST_IMAGES [IMAGE_INDEX]\n",
            program, program, program, program, program);
}

int main(int argc, char **argv)
{
    struct lenet5_board_info info;
    unsigned long image_index = 0;
    unsigned long resident_count;
    unsigned long offset;
    uint32_t space;
    uint32_t value;
    char *end = NULL;
    int fd;
    int result;

    fd = open(DEVICE_PATH, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "FAIL: open %s: %s\n",
                DEVICE_PATH, strerror(errno));
        return EXIT_FAILURE;
    }
    if (ioctl(fd, LENET5_IOC_GET_INFO, &info) < 0) {
        fprintf(stderr, "FAIL: GET_INFO: %s\n", strerror(errno));
        close(fd);
        return EXIT_FAILURE;
    }

    if (argc == 2 && strcmp(argv[1], "--id-only") == 0) {
        result = id_only(fd, &info);
        close(fd);
        return result;
    }

    if (argc == 4 && strcmp(argv[1], "--read-one") == 0) {
        if (strcmp(argv[2], "accel") == 0)
            space = LENET5_REG_SPACE_ACCEL;
        else if (strcmp(argv[2], "dma") == 0)
            space = LENET5_REG_SPACE_DMA;
        else {
            fprintf(stderr, "FAIL: space must be accel or dma\n");
            close(fd);
            return EXIT_FAILURE;
        }

        errno = 0;
        offset = strtoul(argv[3], &end, 0);
        if (errno || !end || *end != '\0' || offset > UINT32_MAX ||
            (offset & 3ul)) {
            fprintf(stderr, "FAIL: invalid aligned register offset\n");
            close(fd);
            return EXIT_FAILURE;
        }

        printf("READ_ONE_BEGIN space=%s offset=%#lx\n", argv[2], offset);
        fflush(stdout);
        value = reg_read(fd, space, (uint32_t)offset);
        printf("READ_ONE_VALUE=%#010x\n", value);
        close(fd);
        return EXIT_SUCCESS;
    }

    if (argc == 6 && strcmp(argv[1], "--stress-resident") == 0) {
        errno = 0;
        resident_count = strtoul(argv[2], &end, 0);
        if (errno || !end || *end != '\0' ||
            resident_count == 0 || resident_count > 100000ul) {
            fprintf(stderr, "FAIL: resident count must be 1..100000\n");
            close(fd);
            return EXIT_FAILURE;
        }
        result = run_resident_stress(fd, &info, argv[3], argv[4],
                                     argv[5], resident_count);
        close(fd);
        return result;
    }

    if (argc == 8 && strcmp(argv[1], "--dataset") == 0) {
        errno = 0;
        resident_count = strtoul(argv[2], &end, 0);
        if (errno || !end || *end != '\0' ||
            resident_count == 0 || resident_count > 10000ul) {
            fprintf(stderr, "FAIL: dataset count must be 1..10000\n");
            close(fd);
            return EXIT_FAILURE;
        }
        result = run_dataset(fd, &info, argv[3], argv[4], argv[5],
                             argv[6], argv[7], resident_count);
        close(fd);
        return result;
    }

    if (argc != 4 && argc != 5) {
        usage(argv[0]);
        close(fd);
        return EXIT_FAILURE;
    }
    if (argc == 5) {
        errno = 0;
        image_index = strtoul(argv[4], &end, 0);
        if (errno || !end || *end != '\0' || image_index >= 10000ul) {
            fprintf(stderr, "FAIL: invalid image index\n");
            close(fd);
            return EXIT_FAILURE;
        }
    }

    result = run_image(fd, &info, argv[1], argv[2], argv[3], image_index,
                       true, 1u,
                       image_index == 0 ? first_expected : NULL,
                       true, true, NULL);
    close(fd);
    return result;
}
