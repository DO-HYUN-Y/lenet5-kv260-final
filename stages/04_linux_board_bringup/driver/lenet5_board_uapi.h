/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
#ifndef LENET5_BOARD_UAPI_H
#define LENET5_BOARD_UAPI_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define LENET5_IOC_MAGIC 0x4c

#define LENET5_REG_SPACE_ACCEL 0u
#define LENET5_REG_SPACE_DMA   1u

struct lenet5_board_info {
    __u64 dma_addr;
    __u64 dma_size;
    __u32 accel_reg_size;
    __u32 dma_reg_size;
    __u32 pl_clock_hz;
    __u32 pl_input_clock_hz;
};

struct lenet5_reg_access {
    __u32 space;
    __u32 offset;
    __u32 value;
    __u32 reserved;
};

#define LENET5_IOC_GET_INFO \
    _IOR(LENET5_IOC_MAGIC, 0x00, struct lenet5_board_info)
#define LENET5_IOC_READ_REG \
    _IOWR(LENET5_IOC_MAGIC, 0x01, struct lenet5_reg_access)
#define LENET5_IOC_WRITE_REG \
    _IOW(LENET5_IOC_MAGIC, 0x02, struct lenet5_reg_access)

#endif
