/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
#ifndef ALEXNET_BOARD_UAPI_H
#define ALEXNET_BOARD_UAPI_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define ALEXNET_IOC_MAGIC 0x41

#define ALEXNET_REG_SPACE_ACCELERATOR 0u
#define ALEXNET_REG_SPACE_MAIN_DMA    1u
#define ALEXNET_REG_SPACE_CAMERA_DMA  2u

struct alexnet_board_info {
    __u64 dma_addr;
    __u64 dma_size;
    __u32 accelerator_reg_size;
    __u32 main_dma_reg_size;
    __u32 camera_dma_reg_size;
    __u32 pl_clock_hz;
    __u32 pl_input_clock_hz;
    __u32 driver_abi_version;
    __u32 reserved[2];
};

struct alexnet_reg_access {
    __u32 space;
    __u32 offset;
    __u32 value;
    __u32 reserved;
};

#define ALEXNET_IOC_GET_INFO \
    _IOR(ALEXNET_IOC_MAGIC, 0x00, struct alexnet_board_info)
#define ALEXNET_IOC_READ_REG \
    _IOWR(ALEXNET_IOC_MAGIC, 0x01, struct alexnet_reg_access)
#define ALEXNET_IOC_WRITE_REG \
    _IOW(ALEXNET_IOC_MAGIC, 0x02, struct alexnet_reg_access)

#endif
