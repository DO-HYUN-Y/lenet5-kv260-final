// SPDX-License-Identifier: MIT
#define _POSIX_C_SOURCE 200809L

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
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "lenet5_board_uapi.h"

#define DEVICE_PATH "/dev/lenet5_board"

#define EXPECTED_ID 0x00024c35u
#define EXPECTED_FABRIC_CLOCK_HZ 149998501u
#define EXPECTED_CORRECT_10000 9893u

#define REG_ID                   0x00u
#define REG_CTRL                 0x04u
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

struct mapped_file {
    int fd;
    size_t size;
    const uint8_t *data;
};

struct aggregate {
    uint64_t prepare_ns;
    uint64_t control_ns;
    uint64_t wait_ns;
    uint64_t verify_ns;
    uint64_t job_cycles;
    uint64_t dma_cycles;
    uint32_t job_min;
    uint32_t job_max;
    uint32_t dma_min;
    uint32_t dma_max;
    unsigned long correct;
    unsigned long busy_samples_missed;
};

static uint64_t monotonic_ns(void)
{
    struct timespec value;

    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) {
        perror("clock_gettime");
        exit(EXIT_FAILURE);
    }
    return (uint64_t)value.tv_sec * UINT64_C(1000000000) +
           (uint64_t)value.tv_nsec;
}

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

static struct mapped_file map_file(const char *path, size_t minimum_size)
{
    struct mapped_file file = {
        .fd = -1,
        .size = 0,
        .data = MAP_FAILED,
    };
    struct stat status;

    file.fd = open(path, O_RDONLY | O_CLOEXEC);
    if (file.fd < 0) {
        fprintf(stderr, "FAIL: open %s: %s\n", path, strerror(errno));
        exit(EXIT_FAILURE);
    }
    if (fstat(file.fd, &status) != 0) {
        fprintf(stderr, "FAIL: stat %s: %s\n", path, strerror(errno));
        exit(EXIT_FAILURE);
    }
    if (status.st_size < 0 || (uint64_t)status.st_size < minimum_size) {
        fprintf(stderr, "FAIL: %s is shorter than %zu bytes\n",
                path, minimum_size);
        exit(EXIT_FAILURE);
    }
    file.size = (size_t)status.st_size;
    file.data = mmap(NULL, file.size, PROT_READ, MAP_PRIVATE, file.fd, 0);
    if (file.data == MAP_FAILED) {
        fprintf(stderr, "FAIL: mmap %s: %s\n", path, strerror(errno));
        exit(EXIT_FAILURE);
    }
    return file;
}

static void unmap_file(struct mapped_file *file)
{
    if (file->data != MAP_FAILED)
        munmap((void *)file->data, file->size);
    if (file->fd >= 0)
        close(file->fd);
}

static void update_range(uint32_t value, uint32_t *minimum,
                         uint32_t *maximum)
{
    if (value < *minimum)
        *minimum = value;
    if (value > *maximum)
        *maximum = value;
}

static int run_job(int fd, const struct lenet5_board_info *info,
                   uint8_t *dma_buffer,
                   const uint8_t *image,
                   uint8_t label,
                   const int8_t *expected,
                   unsigned long image_index,
                   bool reload_model,
                   bool *reload_cfg_active,
                   bool *descriptors_programmed,
                   struct aggregate *aggregate)
{
    uint64_t base = info->dma_addr;
    uint64_t phase_start;
    uint64_t wait_start;
    uint64_t now;
    uint32_t auto_status;
    uint32_t completed_before;
    uint32_t completed_after;
    uint32_t completed_job;
    uint32_t error_code;
    uint32_t mm2s;
    uint32_t s2mm;
    uint32_t job_cycles;
    uint32_t dma_cycles;
    bool saw_busy = false;
    int predicted = 0;

    phase_start = monotonic_ns();
    memcpy(dma_buffer + INPUT_OFFSET, image, INPUT_BYTES);
    memset(dma_buffer + RESULT_OFFSET, 0xa5, 16);
    __sync_synchronize();
    aggregate->prepare_ns += monotonic_ns() - phase_start;

    phase_start = monotonic_ns();
    reg_write(fd, LENET5_REG_SPACE_ACCEL, REG_CTRL, CTRL_CLEAR);
    auto_status =
        reg_read(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_STATUS);
    if (!(auto_status & AUTO_SUBMIT_READY)) {
        fprintf(stderr, "FAIL: scheduler not ready image=%lu status=%#x\n",
                image_index, auto_status);
        return EXIT_FAILURE;
    }
    completed_before =
        reg_read(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_COMPLETED_COUNT);

    if (!*descriptors_programmed) {
        reg_write(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_WEIGHT_ADDR,
                  (uint32_t)(base + WEIGHT_OFFSET));
        reg_write(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_PARAM_ADDR,
                  (uint32_t)(base + PARAM_OFFSET));
        reg_write(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_INPUT_ADDR,
                  (uint32_t)(base + INPUT_OFFSET));
        reg_write(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_RESULT_ADDR,
                  (uint32_t)(base + RESULT_OFFSET));
        reg_write(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_TIMEOUT,
                  100000000u);
        *descriptors_programmed = true;
    }
    if (reload_model) {
        reg_write(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_CFG, 1u);
        *reload_cfg_active = true;
    } else if (*reload_cfg_active) {
        reg_write(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_CFG, 0u);
        *reload_cfg_active = false;
    }
    reg_write(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_JOB_ID,
              (uint32_t)(image_index + 1ul));
    aggregate->control_ns += monotonic_ns() - phase_start;

    wait_start = monotonic_ns();
    reg_write(fd, LENET5_REG_SPACE_ACCEL, REG_CTRL, CTRL_AUTO_SUBMIT);
    for (;;) {
        auto_status =
            reg_read(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_STATUS);
        if (auto_status & AUTO_BUSY)
            saw_busy = true;
        if (auto_status & (AUTO_DONE | AUTO_ERROR))
            break;
        now = monotonic_ns();
        if (now - wait_start > UINT64_C(5000000000)) {
            fprintf(stderr, "FAIL: timeout image=%lu\n", image_index);
            return EXIT_FAILURE;
        }
    }
    aggregate->wait_ns += monotonic_ns() - wait_start;

    phase_start = monotonic_ns();
    __sync_synchronize();
    error_code =
        reg_read(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_ERROR);
    completed_after =
        reg_read(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_COMPLETED_COUNT);
    completed_job =
        reg_read(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_COMPLETED_JOB);
    mm2s = reg_read(fd, LENET5_REG_SPACE_DMA, DMA_MM2S_STATUS);
    s2mm = reg_read(fd, LENET5_REG_SPACE_DMA, DMA_S2MM_STATUS);
    job_cycles =
        reg_read(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_JOB_CYCLES);
    dma_cycles =
        reg_read(fd, LENET5_REG_SPACE_ACCEL, REG_AUTO_DMA_CYCLES);

    if (!(auto_status & AUTO_DONE) || (auto_status & AUTO_ERROR) ||
        error_code != 0) {
        fprintf(stderr,
                "FAIL: scheduler status image=%lu status=%#x error=%#x\n",
                image_index, auto_status, error_code);
        return EXIT_FAILURE;
    }
    if ((mm2s | s2mm) & DMA_ERROR_MASK) {
        fprintf(stderr,
                "FAIL: DMA error image=%lu mm2s=%#x s2mm=%#x\n",
                image_index, mm2s, s2mm);
        return EXIT_FAILURE;
    }
    if (completed_after != completed_before + 1u ||
        completed_job != (uint32_t)(image_index + 1ul)) {
        fprintf(stderr,
                "FAIL: completion image=%lu count=%u->%u job=%u\n",
                image_index, completed_before, completed_after,
                completed_job);
        return EXIT_FAILURE;
    }

    for (size_t i = 0; i < RESULT_BYTES; ++i) {
        int8_t actual = (int8_t)dma_buffer[RESULT_OFFSET + i];

        if (actual != expected[i]) {
            fprintf(stderr,
                    "FAIL: logit image=%lu index=%zu expected=%d actual=%d\n",
                    image_index, i, expected[i], actual);
            return EXIT_FAILURE;
        }
        if ((int8_t)dma_buffer[RESULT_OFFSET + predicted] < actual)
            predicted = (int)i;
    }
    if ((uint8_t)predicted == label)
        aggregate->correct++;
    if (!saw_busy)
        aggregate->busy_samples_missed++;

    aggregate->job_cycles += job_cycles;
    aggregate->dma_cycles += dma_cycles;
    update_range(job_cycles, &aggregate->job_min, &aggregate->job_max);
    update_range(dma_cycles, &aggregate->dma_min, &aggregate->dma_max);
    aggregate->verify_ns += monotonic_ns() - phase_start;
    return EXIT_SUCCESS;
}

static void usage(const char *program)
{
    fprintf(stderr,
            "Usage: %s COUNT WEIGHTS PARAMS TEST_IMAGES LABELS GOLDEN_LOGITS\n",
            program);
}

int main(int argc, char **argv)
{
    struct lenet5_board_info info;
    struct mapped_file weights;
    struct mapped_file params;
    struct mapped_file images;
    struct mapped_file labels;
    struct mapped_file golden;
    struct aggregate aggregate = {
        .job_min = UINT32_MAX,
        .dma_min = UINT32_MAX,
    };
    uint8_t *dma_buffer;
    unsigned long image_count;
    char *end = NULL;
    uint64_t wall_start;
    uint64_t wall_end;
    uint64_t hardware_ns;
    uint64_t runtime_ns;
    bool reload_cfg_active = false;
    bool descriptors_programmed = false;
    int fd;
    int result = EXIT_FAILURE;

    if (argc != 7) {
        usage(argv[0]);
        return EXIT_FAILURE;
    }
    errno = 0;
    image_count = strtoul(argv[1], &end, 0);
    if (errno || !end || *end != '\0' ||
        image_count == 0 || image_count > 10000ul) {
        fprintf(stderr, "FAIL: COUNT must be 1..10000\n");
        return EXIT_FAILURE;
    }

    weights = map_file(argv[2], WEIGHT_BYTES);
    params = map_file(argv[3], PARAM_BYTES);
    images = map_file(argv[4], image_count * INPUT_BYTES);
    labels = map_file(argv[5], image_count);
    golden = map_file(argv[6], image_count * RESULT_BYTES);

    fd = open(DEVICE_PATH, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "FAIL: open %s: %s\n",
                DEVICE_PATH, strerror(errno));
        goto out_files;
    }
    if (ioctl(fd, LENET5_IOC_GET_INFO, &info) < 0) {
        fprintf(stderr, "FAIL: GET_INFO: %s\n", strerror(errno));
        goto out_device;
    }
    if (info.pl_clock_hz != EXPECTED_FABRIC_CLOCK_HZ ||
        info.dma_size < USED_BYTES ||
        info.dma_addr + USED_BYTES > UINT32_MAX) {
        fprintf(stderr,
                "FAIL: board contract clock=%u dma=%#" PRIx64 "/%" PRIu64 "\n",
                info.pl_clock_hz, (uint64_t)info.dma_addr,
                (uint64_t)info.dma_size);
        goto out_device;
    }
    if (reg_read(fd, LENET5_REG_SPACE_ACCEL, REG_ID) != EXPECTED_ID) {
        fprintf(stderr, "FAIL: accelerator ID mismatch\n");
        goto out_device;
    }

    wall_start = monotonic_ns();
    dma_buffer = mmap(NULL, info.dma_size, PROT_READ | PROT_WRITE,
                      MAP_SHARED, fd, 0);
    if (dma_buffer == MAP_FAILED) {
        fprintf(stderr, "FAIL: mmap coherent DMA buffer: %s\n",
                strerror(errno));
        goto out_device;
    }
    memcpy(dma_buffer + WEIGHT_OFFSET, weights.data, WEIGHT_BYTES);
    memcpy(dma_buffer + PARAM_OFFSET, params.data, PARAM_BYTES);
    __sync_synchronize();

    for (unsigned long i = 0; i < image_count; ++i) {
        result = run_job(
            fd, &info, dma_buffer,
            images.data + i * INPUT_BYTES,
            labels.data[i],
            (const int8_t *)(golden.data + i * RESULT_BYTES),
            i, i == 0, &reload_cfg_active, &descriptors_programmed,
            &aggregate);
        if (result != EXIT_SUCCESS)
            goto out_dma;
        if ((i + 1ul) % 1000ul == 0 || i + 1ul == image_count) {
            printf("PERSISTENT_PROGRESS=%lu/%lu CORRECT=%lu\n",
                   i + 1ul, image_count, aggregate.correct);
            fflush(stdout);
        }
    }
    wall_end = monotonic_ns();
    hardware_ns = aggregate.job_cycles * UINT64_C(1000000000) /
                  info.pl_clock_hz;
    runtime_ns = wall_end - wall_start;

    printf("PERSISTENT_BYTE_EXACT_IMAGES=%lu LOGIT_BYTES=%lu\n",
           image_count, image_count * RESULT_BYTES);
    printf("PERSISTENT_ACCURACY=%.4f%% CORRECT=%lu/%lu\n",
           100.0 * (double)aggregate.correct / (double)image_count,
           aggregate.correct, image_count);
    printf("PERSISTENT_JOB_CYCLES_AVG=%.3f MIN=%u MAX=%u\n",
           (double)aggregate.job_cycles / (double)image_count,
           aggregate.job_min, aggregate.job_max);
    printf("PERSISTENT_DMA_CYCLES_AVG=%.3f MIN=%u MAX=%u\n",
           (double)aggregate.dma_cycles / (double)image_count,
           aggregate.dma_min, aggregate.dma_max);
    printf("PERSISTENT_PHASE_US_PER_IMAGE prepare=%.3f control=%.3f wait=%.3f verify=%.3f\n",
           (double)aggregate.prepare_ns / (double)image_count / 1000.0,
           (double)aggregate.control_ns / (double)image_count / 1000.0,
           (double)aggregate.wait_ns / (double)image_count / 1000.0,
           (double)aggregate.verify_ns / (double)image_count / 1000.0);
    printf("PERSISTENT_HARDWARE_SECONDS=%.6f WALL_SECONDS=%.6f IMAGES_PER_SECOND=%.3f\n",
           (double)hardware_ns / 1.0e9,
           (double)runtime_ns / 1.0e9,
           (double)image_count * 1.0e9 / (double)runtime_ns);
    printf("PERSISTENT_PL_JOB_BUSY_PERCENT=%.3f BUSY_SAMPLES_MISSED=%lu\n",
           100.0 * (double)hardware_ns / (double)runtime_ns,
           aggregate.busy_samples_missed);

    if (image_count == 10000ul &&
        aggregate.correct != EXPECTED_CORRECT_10000) {
        fprintf(stderr,
                "FAIL: accuracy expected=%u actual=%lu\n",
                EXPECTED_CORRECT_10000, aggregate.correct);
        result = EXIT_FAILURE;
        goto out_dma;
    }
    printf("LENET5_PERSISTENT_RUNTIME_PASS images=%lu\n", image_count);
    result = EXIT_SUCCESS;

out_dma:
    munmap(dma_buffer, info.dma_size);
out_device:
    close(fd);
out_files:
    unmap_file(&golden);
    unmap_file(&labels);
    unmap_file(&images);
    unmap_file(&params);
    unmap_file(&weights);
    return result;
}
