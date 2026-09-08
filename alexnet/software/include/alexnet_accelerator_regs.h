#ifndef ALEXNET_ACCELERATOR_REGS_H
#define ALEXNET_ACCELERATOR_REGS_H

#include <stdint.h>

#include "alexnet_buffer_layout.h"

#define ALEXNET_ACCELERATOR_BASE        0xA0000000u
#define ALEXNET_MAIN_DMA_BASE           0xA0010000u
#define ALEXNET_CAMERA_DMA_BASE         0xA0020000u

#define ALEXNET_IRQ_ACCELERATOR          0u
#define ALEXNET_IRQ_MAIN_MM2S            1u
#define ALEXNET_IRQ_MAIN_S2MM            2u
#define ALEXNET_IRQ_CAMERA_MM2S          3u
#define ALEXNET_IRQ_CAMERA_FORMAT_ERROR  4u

#define ALEXNET_REG_ID                 0x00u
#define ALEXNET_REG_CONTROL            0x04u
#define ALEXNET_REG_STATUS             0x08u
#define ALEXNET_REG_JOB_TAG            0x0cu
#define ALEXNET_REG_INPUT_LO           0x10u
#define ALEXNET_REG_INPUT_HI           0x14u
#define ALEXNET_REG_ACT_A_LO           0x18u
#define ALEXNET_REG_ACT_A_HI           0x1cu
#define ALEXNET_REG_ACT_B_LO           0x20u
#define ALEXNET_REG_ACT_B_HI           0x24u
#define ALEXNET_REG_WEIGHTS_LO         0x28u
#define ALEXNET_REG_WEIGHTS_HI         0x2cu
#define ALEXNET_REG_PARAMETERS_LO      0x30u
#define ALEXNET_REG_PARAMETERS_HI      0x34u
#define ALEXNET_REG_OUTPUT_LO          0x38u
#define ALEXNET_REG_OUTPUT_HI          0x3cu
#define ALEXNET_REG_DMA_TIMEOUT        0x40u
#define ALEXNET_REG_PROGRESS           0x44u
#define ALEXNET_REG_ERROR              0x48u
#define ALEXNET_REG_ACTIVE_TAG         0x4cu
#define ALEXNET_REG_DMA_ACCEPTED       0x50u
#define ALEXNET_REG_DMA_ISSUED         0x54u
#define ALEXNET_REG_DMA_COMPLETED      0x58u
#define ALEXNET_REG_CONV_TILES         0x5cu
#define ALEXNET_REG_IRQ_ENABLE         0x60u
#define ALEXNET_REG_IRQ_STATUS         0x64u
#define ALEXNET_REG_LAST_JOB_CYCLES    0x68u
#define ALEXNET_REG_COMPLETED_JOBS     0x6cu
#define ALEXNET_REG_REJECTED_SUBMITS   0x70u
#define ALEXNET_REG_FAILED_JOBS        0x74u
#define ALEXNET_REG_CONFIG_STATUS      0x78u
#define ALEXNET_REG_BUILD_CONFIG       0x7cu

#define ALEXNET_CONTROL_SUBMIT         (1u << 0)
#define ALEXNET_CONTROL_CLEAR_STATUS   (1u << 1)
#define ALEXNET_CONTROL_CANCEL_PENDING (1u << 2)

#define ALEXNET_STATUS_BUSY            (1u << 0)
#define ALEXNET_STATUS_START_PENDING   (1u << 1)
#define ALEXNET_STATUS_START_READY     (1u << 2)
#define ALEXNET_STATUS_DONE            (1u << 3)
#define ALEXNET_STATUS_FAILED          (1u << 4)
#define ALEXNET_STATUS_FAULT           (1u << 5)
#define ALEXNET_STATUS_LIVE_FAULT      (1u << 6)
#define ALEXNET_STATUS_DMA_BUSY        (1u << 7)
#define ALEXNET_STATUS_DMA_ERROR       (1u << 8)
#define ALEXNET_STATUS_POOL5_VALID     (1u << 9)
#define ALEXNET_STATUS_IRQ             (1u << 10)
#define ALEXNET_STATUS_SUBMIT_REJECTED (1u << 11)
#define ALEXNET_STATUS_CONFIG_VALID    (1u << 12)

#define ALEXNET_IRQ_DONE               (1u << 0)
#define ALEXNET_IRQ_FAILED             (1u << 1)
#define ALEXNET_IRQ_FAULT              (1u << 2)
#define ALEXNET_IRQ_SUBMIT_REJECTED    (1u << 3)
#define ALEXNET_IRQ_ENABLE_DONE        (1u << 0)
#define ALEXNET_IRQ_ENABLE_ERROR       (1u << 1)

#define ALEXNET_EXPECTED_ID            0x414c0100u
#define ALEXNET_EXPECTED_BUILD_CONFIG  0x040800c8u

/* Xilinx AXI DMA simple-mode MM2S registers used for the camera stream. */
#define ALEXNET_AXIDMA_MM2S_DMACR      0x00u
#define ALEXNET_AXIDMA_MM2S_DMASR      0x04u
#define ALEXNET_AXIDMA_MM2S_SA         0x18u
#define ALEXNET_AXIDMA_MM2S_SA_MSB     0x1cu
#define ALEXNET_AXIDMA_MM2S_LENGTH     0x28u

#define ALEXNET_AXIDMA_DMACR_RUNSTOP       (1u << 0)
#define ALEXNET_AXIDMA_DMACR_RESET         (1u << 2)
#define ALEXNET_AXIDMA_DMACR_IOC_IRQEN     (1u << 12)
#define ALEXNET_AXIDMA_DMACR_ERR_IRQEN     (1u << 14)
#define ALEXNET_AXIDMA_DMASR_HALTED         (1u << 0)
#define ALEXNET_AXIDMA_DMASR_IDLE           (1u << 1)
#define ALEXNET_AXIDMA_DMASR_ERROR_MASK     0x00000770u
#define ALEXNET_AXIDMA_DMASR_IOC_IRQ        (1u << 12)
#define ALEXNET_AXIDMA_DMASR_ERR_IRQ        (1u << 14)

static inline void alexnet_write64(volatile uint32_t *regs,
                                   uint32_t low_offset,
                                   uint64_t value)
{
    regs[low_offset / 4u] = (uint32_t)value;
    regs[(low_offset + 4u) / 4u] = (uint32_t)(value >> 32);
}

#endif
