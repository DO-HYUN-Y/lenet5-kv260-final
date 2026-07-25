// SPDX-License-Identifier: GPL-2.0
/*
 * Linux bring-up driver for the Stage05 KV260 LeNet-5 accelerator.
 *
 * The platform node supplies the accelerator and AXI DMA CSR resources.
 * Userspace receives a coherent, 32-bit-addressable DMA buffer plus bounded
 * CSR ioctls. The driver intentionally does not own job scheduling.
 */

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

#include "lenet5_board_uapi.h"

#define LENET5_DEVICE_NAME "lenet5_board"
#define LENET5_CLASS_NAME  "lenet5"
#define LENET5_DMA_BYTES   (128u * 1024u)
#define LENET5_PL0_INPUT_MIN_HZ 90000000u
#define LENET5_PL0_INPUT_MAX_HZ 110000000u
#define LENET5_FABRIC_CLOCK_HZ 149998501u
#define LENET5_FABRIC_CLOCK_TOLERANCE_HZ 5000u

struct lenet5_board_dev {
    struct device *dev;
    void __iomem *accel_regs;
    void __iomem *dma_regs;
    resource_size_t accel_reg_size;
    resource_size_t dma_reg_size;
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

static int lenet5_open(struct inode *inode, struct file *file)
{
    struct lenet5_board_dev *ldev;

    ldev = container_of(inode->i_cdev, struct lenet5_board_dev, cdev);
    file->private_data = ldev;
    return 0;
}

static void __iomem *lenet5_select_regs(struct lenet5_board_dev *ldev,
                                        u32 space,
                                        resource_size_t *size)
{
    if (space == LENET5_REG_SPACE_ACCEL) {
        *size = ldev->accel_reg_size;
        return ldev->accel_regs;
    }
    if (space == LENET5_REG_SPACE_DMA) {
        *size = ldev->dma_reg_size;
        return ldev->dma_regs;
    }
    return NULL;
}

static long lenet5_ioctl(struct file *file, unsigned int cmd,
                         unsigned long arg)
{
    struct lenet5_board_dev *ldev = file->private_data;
    struct lenet5_board_info info;
    struct lenet5_reg_access access;
    resource_size_t reg_size;
    void __iomem *regs;

    switch (cmd) {
    case LENET5_IOC_GET_INFO:
        memset(&info, 0, sizeof(info));
        info.dma_addr = (u64)ldev->dma_addr;
        info.dma_size = (u64)ldev->dma_size;
        info.accel_reg_size = (u32)ldev->accel_reg_size;
        info.dma_reg_size = (u32)ldev->dma_reg_size;
        info.pl_clock_hz = (u32)ldev->pl_clock_hz;
        info.pl_input_clock_hz = (u32)ldev->pl_input_clock_hz;
        if (copy_to_user((void __user *)arg, &info, sizeof(info)))
            return -EFAULT;
        return 0;

    case LENET5_IOC_READ_REG:
        if (copy_from_user(&access, (void __user *)arg, sizeof(access)))
            return -EFAULT;
        regs = lenet5_select_regs(ldev, access.space, &reg_size);
        if (!regs || (access.offset & 3u) ||
            access.offset > reg_size - sizeof(u32))
            return -EINVAL;
        mutex_lock(&ldev->reg_lock);
        access.value = readl(regs + access.offset);
        mutex_unlock(&ldev->reg_lock);
        if (copy_to_user((void __user *)arg, &access, sizeof(access)))
            return -EFAULT;
        return 0;

    case LENET5_IOC_WRITE_REG:
        if (copy_from_user(&access, (void __user *)arg, sizeof(access)))
            return -EFAULT;
        regs = lenet5_select_regs(ldev, access.space, &reg_size);
        if (!regs || (access.offset & 3u) ||
            access.offset > reg_size - sizeof(u32))
            return -EINVAL;
        mutex_lock(&ldev->reg_lock);
        writel(access.value, regs + access.offset);
        wmb();
        mutex_unlock(&ldev->reg_lock);
        return 0;

    default:
        return -ENOTTY;
    }
}

static int lenet5_mmap(struct file *file, struct vm_area_struct *vma)
{
    struct lenet5_board_dev *ldev = file->private_data;
    size_t requested = vma->vm_end - vma->vm_start;

    if (vma->vm_pgoff != 0 || requested > ldev->dma_size)
        return -EINVAL;

    return dma_mmap_coherent(ldev->dev, vma, ldev->dma_cpu,
                             ldev->dma_addr, ldev->dma_size);
}

static const struct file_operations lenet5_fops = {
    .owner = THIS_MODULE,
    .open = lenet5_open,
    .unlocked_ioctl = lenet5_ioctl,
#ifdef CONFIG_COMPAT
    .compat_ioctl = lenet5_ioctl,
#endif
    .mmap = lenet5_mmap,
    .llseek = no_llseek,
};

static int lenet5_chrdev_create(struct lenet5_board_dev *ldev)
{
    int ret;

    ret = alloc_chrdev_region(&ldev->devt, 0, 1, LENET5_DEVICE_NAME);
    if (ret)
        return ret;

    cdev_init(&ldev->cdev, &lenet5_fops);
    ldev->cdev.owner = THIS_MODULE;
    ret = cdev_add(&ldev->cdev, ldev->devt, 1);
    if (ret)
        goto err_unregister;

    ldev->class = class_create(THIS_MODULE, LENET5_CLASS_NAME);
    if (IS_ERR(ldev->class)) {
        ret = PTR_ERR(ldev->class);
        goto err_cdev;
    }

    ldev->char_dev = device_create(ldev->class, ldev->dev, ldev->devt,
                                   NULL, LENET5_DEVICE_NAME);
    if (IS_ERR(ldev->char_dev)) {
        ret = PTR_ERR(ldev->char_dev);
        goto err_class;
    }
    return 0;

err_class:
    class_destroy(ldev->class);
err_cdev:
    cdev_del(&ldev->cdev);
err_unregister:
    unregister_chrdev_region(ldev->devt, 1);
    return ret;
}

static void lenet5_chrdev_destroy(struct lenet5_board_dev *ldev)
{
    device_destroy(ldev->class, ldev->devt);
    class_destroy(ldev->class);
    cdev_del(&ldev->cdev);
    unregister_chrdev_region(ldev->devt, 1);
}

static bool lenet5_pl0_input_matches(unsigned long rate)
{
    return rate >= LENET5_PL0_INPUT_MIN_HZ &&
           rate <= LENET5_PL0_INPUT_MAX_HZ;
}

static int lenet5_configure_pl_clock(struct lenet5_board_dev *ldev)
{
    u32 fabric_clock_hz;
    int ret;

    ldev->pl_input_clock_hz = clk_get_rate(ldev->pl_clk);
    if (!lenet5_pl0_input_matches(ldev->pl_input_clock_hz)) {
        dev_err(ldev->dev,
                "PL0 input %lu Hz is outside Stage05 range %u..%u\n",
                ldev->pl_input_clock_hz, LENET5_PL0_INPUT_MIN_HZ,
                LENET5_PL0_INPUT_MAX_HZ);
        return -ERANGE;
    }

    ret = of_property_read_u32(ldev->dev->of_node,
                               "yun,fabric-clock-hz",
                               &fabric_clock_hz);
    if (ret) {
        dev_err(ldev->dev,
                "missing Stage05 yun,fabric-clock-hz property\n");
        return ret;
    }
    if (fabric_clock_hz < LENET5_FABRIC_CLOCK_HZ -
            LENET5_FABRIC_CLOCK_TOLERANCE_HZ ||
        fabric_clock_hz > LENET5_FABRIC_CLOCK_HZ +
            LENET5_FABRIC_CLOCK_TOLERANCE_HZ) {
        dev_err(ldev->dev,
                "fabric clock %u Hz does not match Stage05 target %u Hz\n",
                fabric_clock_hz, LENET5_FABRIC_CLOCK_HZ);
        return -ERANGE;
    }
    ldev->pl_clock_hz = fabric_clock_hz;

    return 0;
}

static int lenet5_probe(struct platform_device *pdev)
{
    struct lenet5_board_dev *ldev;
    struct resource *resource;
    int ret;

    ldev = devm_kzalloc(&pdev->dev, sizeof(*ldev), GFP_KERNEL);
    if (!ldev)
        return -ENOMEM;

    ldev->dev = &pdev->dev;
    ldev->dma_size = LENET5_DMA_BYTES;
    mutex_init(&ldev->reg_lock);

    resource = platform_get_resource_byname(pdev, IORESOURCE_MEM, "accel");
    if (!resource)
        return dev_err_probe(&pdev->dev, -ENODEV,
                             "missing accel register resource\n");
    ldev->accel_regs = devm_ioremap_resource(&pdev->dev, resource);
    if (IS_ERR(ldev->accel_regs))
        return PTR_ERR(ldev->accel_regs);
    ldev->accel_reg_size = resource_size(resource);

    resource = platform_get_resource_byname(pdev, IORESOURCE_MEM, "dma");
    if (!resource)
        return dev_err_probe(&pdev->dev, -ENODEV,
                             "missing DMA register resource\n");
    ldev->dma_regs = devm_ioremap_resource(&pdev->dev, resource);
    if (IS_ERR(ldev->dma_regs))
        return PTR_ERR(ldev->dma_regs);
    ldev->dma_reg_size = resource_size(resource);

    ldev->pl_clk = devm_clk_get(&pdev->dev, "pl_clk0");
    if (IS_ERR(ldev->pl_clk))
        return dev_err_probe(&pdev->dev, PTR_ERR(ldev->pl_clk),
                             "failed to acquire PL0 clock\n");

    ret = lenet5_configure_pl_clock(ldev);
    if (ret)
        return ret;

    ret = clk_prepare_enable(ldev->pl_clk);
    if (ret)
        return dev_err_probe(&pdev->dev, ret,
                             "failed to enable firmware-owned PL0 clock\n");

    ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(32));
    if (ret) {
        dev_err(&pdev->dev, "32-bit DMA mask is unavailable\n");
        goto err_clock;
    }

    ldev->dma_cpu = dma_alloc_coherent(&pdev->dev, ldev->dma_size,
                                       &ldev->dma_addr, GFP_KERNEL);
    if (!ldev->dma_cpu) {
        ret = -ENOMEM;
        goto err_clock;
    }
    if (upper_32_bits(ldev->dma_addr)) {
        dev_err(&pdev->dev, "DMA address is outside 32-bit range: %pad\n",
                &ldev->dma_addr);
        ret = -ERANGE;
        goto err_dma;
    }
    memset(ldev->dma_cpu, 0, ldev->dma_size);

    ret = lenet5_chrdev_create(ldev);
    if (ret)
        goto err_dma;

    platform_set_drvdata(pdev, ldev);
    dev_info(&pdev->dev,
             "ready: dma=%pad size=%zu PL0-input=%lu Hz fabric=%lu Hz\n",
             &ldev->dma_addr, ldev->dma_size,
             ldev->pl_input_clock_hz, ldev->pl_clock_hz);
    return 0;

err_dma:
    dma_free_coherent(&pdev->dev, ldev->dma_size,
                      ldev->dma_cpu, ldev->dma_addr);
err_clock:
    clk_disable_unprepare(ldev->pl_clk);
    return ret;
}

static int lenet5_remove(struct platform_device *pdev)
{
    struct lenet5_board_dev *ldev = platform_get_drvdata(pdev);

    lenet5_chrdev_destroy(ldev);
    dma_free_coherent(&pdev->dev, ldev->dma_size,
                      ldev->dma_cpu, ldev->dma_addr);
    clk_disable_unprepare(ldev->pl_clk);
    return 0;
}

static const struct of_device_id lenet5_of_match[] = {
    { .compatible = "yun,lenet5-kv260-board-1.1" },
    { }
};
MODULE_DEVICE_TABLE(of, lenet5_of_match);

static struct platform_driver lenet5_driver = {
    .probe = lenet5_probe,
    .remove = lenet5_remove,
    .driver = {
        .name = LENET5_DEVICE_NAME,
        .of_match_table = lenet5_of_match,
    },
};
module_platform_driver(lenet5_driver);

MODULE_AUTHOR("LeNet-5 KV260 project");
MODULE_DESCRIPTION("KV260 LeNet-5 coherent buffer and CSR bring-up driver");
MODULE_LICENSE("GPL");
