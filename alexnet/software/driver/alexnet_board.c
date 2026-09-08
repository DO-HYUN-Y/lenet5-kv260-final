// SPDX-License-Identifier: GPL-2.0
/* KV260 Linux bridge for the AlexNet accelerator and its two AXI DMAs. */

#include <linux/cdev.h>
#include <linux/clk.h>
#include <linux/device.h>
#include <linux/dma-mapping.h>
#include <linux/fs.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/version.h>

#include "alexnet_board_uapi.h"
#include "../include/alexnet_buffer_layout.h"

#define ALEXNET_DEVICE_NAME "alexnet_board"
#define ALEXNET_CLASS_NAME "alexnet"
#define ALEXNET_DRIVER_ABI_VERSION 2u
#define ALEXNET_PL0_INPUT_MIN_HZ 90000000u
#define ALEXNET_PL0_INPUT_MAX_HZ 110000000u
#define ALEXNET_FABRIC_CLOCK_HZ 199998002u
#define ALEXNET_FABRIC_CLOCK_TOLERANCE_HZ 5000u

struct alexnet_board_dev {
    struct device *dev;
    void __iomem *accelerator_regs;
    void __iomem *main_dma_regs;
    void __iomem *camera_dma_regs;
    resource_size_t accelerator_reg_size;
    resource_size_t main_dma_reg_size;
    resource_size_t camera_dma_reg_size;
    struct clk *pl_clk;
    unsigned long pl_input_clock_hz;
    unsigned long pl_clock_hz;

    void *dma_cpu;
    dma_addr_t dma_addr;
    size_t dma_size;

    dev_t devt;
    struct cdev cdev;
    struct class *class;
    struct device *char_dev;
    struct mutex reg_lock;
};

static int alexnet_open(struct inode *inode, struct file *file)
{
    struct alexnet_board_dev *adev;

    adev = container_of(inode->i_cdev, struct alexnet_board_dev, cdev);
    file->private_data = adev;
    return 0;
}

static void __iomem *alexnet_select_regs(struct alexnet_board_dev *adev,
                                         u32 space,
                                         resource_size_t *size)
{
    switch (space) {
    case ALEXNET_REG_SPACE_ACCELERATOR:
        *size = adev->accelerator_reg_size;
        return adev->accelerator_regs;
    case ALEXNET_REG_SPACE_MAIN_DMA:
        *size = adev->main_dma_reg_size;
        return adev->main_dma_regs;
    case ALEXNET_REG_SPACE_CAMERA_DMA:
        *size = adev->camera_dma_reg_size;
        return adev->camera_dma_regs;
    default:
        return NULL;
    }
}

static long alexnet_ioctl(struct file *file, unsigned int cmd,
                          unsigned long arg)
{
    struct alexnet_board_dev *adev = file->private_data;
    struct alexnet_board_info info;
    struct alexnet_reg_access access;
    resource_size_t reg_size;
    void __iomem *regs;

    switch (cmd) {
    case ALEXNET_IOC_GET_INFO:
        memset(&info, 0, sizeof(info));
        info.dma_addr = (u64)adev->dma_addr;
        info.dma_size = (u64)adev->dma_size;
        info.accelerator_reg_size = (u32)adev->accelerator_reg_size;
        info.main_dma_reg_size = (u32)adev->main_dma_reg_size;
        info.camera_dma_reg_size = (u32)adev->camera_dma_reg_size;
        info.pl_clock_hz = (u32)adev->pl_clock_hz;
        info.pl_input_clock_hz = (u32)adev->pl_input_clock_hz;
        info.driver_abi_version = ALEXNET_DRIVER_ABI_VERSION;
        if (copy_to_user((void __user *)arg, &info, sizeof(info)))
            return -EFAULT;
        return 0;

    case ALEXNET_IOC_READ_REG:
        if (copy_from_user(&access, (void __user *)arg, sizeof(access)))
            return -EFAULT;
        regs = alexnet_select_regs(adev, access.space, &reg_size);
        if (!regs || (access.offset & 3u) ||
            access.offset > reg_size - sizeof(u32))
            return -EINVAL;
        mutex_lock(&adev->reg_lock);
        access.value = readl(regs + access.offset);
        mutex_unlock(&adev->reg_lock);
        if (copy_to_user((void __user *)arg, &access, sizeof(access)))
            return -EFAULT;
        return 0;

    case ALEXNET_IOC_WRITE_REG:
        if (copy_from_user(&access, (void __user *)arg, sizeof(access)))
            return -EFAULT;
        regs = alexnet_select_regs(adev, access.space, &reg_size);
        if (!regs || (access.offset & 3u) ||
            access.offset > reg_size - sizeof(u32))
            return -EINVAL;
        mutex_lock(&adev->reg_lock);
        writel(access.value, regs + access.offset);
        wmb();
        mutex_unlock(&adev->reg_lock);
        return 0;

    default:
        return -ENOTTY;
    }
}

static int alexnet_mmap(struct file *file, struct vm_area_struct *vma)
{
    struct alexnet_board_dev *adev = file->private_data;
    size_t requested = vma->vm_end - vma->vm_start;

    if (vma->vm_pgoff != 0 || requested > adev->dma_size)
        return -EINVAL;
    return dma_mmap_coherent(adev->dev, vma, adev->dma_cpu,
                             adev->dma_addr, adev->dma_size);
}

static const struct file_operations alexnet_fops = {
    .owner = THIS_MODULE,
    .open = alexnet_open,
    .unlocked_ioctl = alexnet_ioctl,
#ifdef CONFIG_COMPAT
    .compat_ioctl = alexnet_ioctl,
#endif
    .mmap = alexnet_mmap,
    .llseek = no_llseek,
};

static int alexnet_chrdev_create(struct alexnet_board_dev *adev)
{
    int ret;

    ret = alloc_chrdev_region(&adev->devt, 0, 1, ALEXNET_DEVICE_NAME);
    if (ret)
        return ret;
    cdev_init(&adev->cdev, &alexnet_fops);
    adev->cdev.owner = THIS_MODULE;
    ret = cdev_add(&adev->cdev, adev->devt, 1);
    if (ret)
        goto err_unregister;

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 4, 0)
    adev->class = class_create(ALEXNET_CLASS_NAME);
#else
    adev->class = class_create(THIS_MODULE, ALEXNET_CLASS_NAME);
#endif
    if (IS_ERR(adev->class)) {
        ret = PTR_ERR(adev->class);
        goto err_cdev;
    }
    adev->char_dev = device_create(adev->class, adev->dev, adev->devt,
                                   NULL, ALEXNET_DEVICE_NAME);
    if (IS_ERR(adev->char_dev)) {
        ret = PTR_ERR(adev->char_dev);
        goto err_class;
    }
    return 0;

err_class:
    class_destroy(adev->class);
err_cdev:
    cdev_del(&adev->cdev);
err_unregister:
    unregister_chrdev_region(adev->devt, 1);
    return ret;
}

static void alexnet_chrdev_destroy(struct alexnet_board_dev *adev)
{
    device_destroy(adev->class, adev->devt);
    class_destroy(adev->class);
    cdev_del(&adev->cdev);
    unregister_chrdev_region(adev->devt, 1);
}

static int alexnet_map_resource(struct platform_device *pdev,
                                const char *name,
                                void __iomem **mapped,
                                resource_size_t *size)
{
    struct resource *resource;

    resource = platform_get_resource_byname(pdev, IORESOURCE_MEM, name);
    if (!resource)
        return dev_err_probe(&pdev->dev, -ENODEV,
                             "missing %s register resource\n", name);
    *mapped = devm_ioremap_resource(&pdev->dev, resource);
    if (IS_ERR(*mapped))
        return PTR_ERR(*mapped);
    *size = resource_size(resource);
    return 0;
}

static int alexnet_probe(struct platform_device *pdev)
{
    struct alexnet_board_dev *adev;
    unsigned long clock_delta;
    u32 fabric_clock_hz;
    int ret;

    adev = devm_kzalloc(&pdev->dev, sizeof(*adev), GFP_KERNEL);
    if (!adev)
        return -ENOMEM;
    adev->dev = &pdev->dev;
    /* mmap VMAs are page-rounded, so allocate the page-rounded size too. */
    adev->dma_size = PAGE_ALIGN((size_t)ALEXNET_DMA_USED_BYTES);
    mutex_init(&adev->reg_lock);

    ret = alexnet_map_resource(pdev, "accelerator", &adev->accelerator_regs,
                               &adev->accelerator_reg_size);
    if (ret)
        return ret;
    ret = alexnet_map_resource(pdev, "main-dma", &adev->main_dma_regs,
                               &adev->main_dma_reg_size);
    if (ret)
        return ret;
    ret = alexnet_map_resource(pdev, "camera-dma", &adev->camera_dma_regs,
                               &adev->camera_dma_reg_size);
    if (ret)
        return ret;

    adev->pl_clk = devm_clk_get(&pdev->dev, "pl_clk0");
    if (IS_ERR(adev->pl_clk))
        return dev_err_probe(&pdev->dev, PTR_ERR(adev->pl_clk),
                             "failed to acquire PL0 clock\n");
    adev->pl_input_clock_hz = clk_get_rate(adev->pl_clk);
    if (adev->pl_input_clock_hz < ALEXNET_PL0_INPUT_MIN_HZ ||
        adev->pl_input_clock_hz > ALEXNET_PL0_INPUT_MAX_HZ)
        return dev_err_probe(
            &pdev->dev, -ERANGE,
            "PL0 input %lu Hz is outside the required 100 MHz range\n",
            adev->pl_input_clock_hz);
    ret = of_property_read_u32(pdev->dev.of_node,
                               "yun,fabric-clock-hz", &fabric_clock_hz);
    if (ret)
        return dev_err_probe(&pdev->dev, ret,
                             "missing yun,fabric-clock-hz\n");
    clock_delta = fabric_clock_hz > ALEXNET_FABRIC_CLOCK_HZ ?
        fabric_clock_hz - ALEXNET_FABRIC_CLOCK_HZ :
        ALEXNET_FABRIC_CLOCK_HZ - fabric_clock_hz;
    if (clock_delta > ALEXNET_FABRIC_CLOCK_TOLERANCE_HZ)
        return dev_err_probe(
            &pdev->dev, -ERANGE,
            "fabric clock metadata %u Hz does not match required 200 MHz\n",
            fabric_clock_hz);
    adev->pl_clock_hz = fabric_clock_hz;
    ret = clk_prepare_enable(adev->pl_clk);
    if (ret)
        return dev_err_probe(&pdev->dev, ret,
                             "failed to enable PL0 clock\n");

    ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(32));
    if (ret) {
        dev_err(&pdev->dev, "32-bit DMA mask is unavailable\n");
        goto err_clock;
    }
    adev->dma_cpu = dma_alloc_coherent(&pdev->dev, adev->dma_size,
                                        &adev->dma_addr, GFP_KERNEL);
    if (!adev->dma_cpu) {
        dev_err(&pdev->dev,
                "failed to allocate %zu DMA bytes; reserve at least 128 MiB CMA\n",
                adev->dma_size);
        ret = -ENOMEM;
        goto err_clock;
    }
    if (upper_32_bits(adev->dma_addr) ||
        (u64)adev->dma_addr + adev->dma_size > (1ULL << 32) ||
        ((u64)adev->dma_addr & (ALEXNET_BASE_ALIGNMENT - 1u))) {
        dev_err(&pdev->dev, "DMA base is unusable: %pad\n", &adev->dma_addr);
        ret = -ERANGE;
        goto err_dma;
    }
    memset(adev->dma_cpu, 0, adev->dma_size);

    ret = alexnet_chrdev_create(adev);
    if (ret)
        goto err_dma;
    platform_set_drvdata(pdev, adev);
    dev_info(&pdev->dev,
             "ready: dma=%pad size=%zu PL0=%lu Hz fabric=%lu Hz ABI=%u\n",
             &adev->dma_addr, adev->dma_size, adev->pl_input_clock_hz,
             adev->pl_clock_hz,
             ALEXNET_DRIVER_ABI_VERSION);
    return 0;

err_dma:
    dma_free_coherent(&pdev->dev, adev->dma_size,
                      adev->dma_cpu, adev->dma_addr);
err_clock:
    clk_disable_unprepare(adev->pl_clk);
    return ret;
}

static int alexnet_remove(struct platform_device *pdev)
{
    struct alexnet_board_dev *adev = platform_get_drvdata(pdev);

    alexnet_chrdev_destroy(adev);
    dma_free_coherent(&pdev->dev, adev->dma_size,
                      adev->dma_cpu, adev->dma_addr);
    clk_disable_unprepare(adev->pl_clk);
    return 0;
}

static const struct of_device_id alexnet_of_match[] = {
    { .compatible = "yun,alexnet-kv260-board-1.0" },
    { }
};
MODULE_DEVICE_TABLE(of, alexnet_of_match);

static struct platform_driver alexnet_driver = {
    .probe = alexnet_probe,
    .remove = alexnet_remove,
    .driver = {
        .name = ALEXNET_DEVICE_NAME,
        .of_match_table = alexnet_of_match,
    },
};
module_platform_driver(alexnet_driver);

MODULE_AUTHOR("KV260 AlexNet project");
MODULE_DESCRIPTION("KV260 AlexNet coherent DMA buffer and CSR bridge");
MODULE_LICENSE("GPL");
