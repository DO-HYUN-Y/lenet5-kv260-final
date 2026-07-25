#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
stage_dir=$(cd "${script_dir}/.." && pwd)
firmware_dir="${stage_dir}/build/firmware"
module_path="${stage_dir}/driver/lenet5_board.ko"
test_path="${stage_dir}/software/lenet5_board_test"
weight_path="${stage_dir}/data/weights_hw.bin"
param_path="${stage_dir}/data/params_hw.bin"
image_path="${stage_dir}/data/test_images.bin"
label_path="${stage_dir}/data/test_labels.bin"
golden_logit_path="${stage_dir}/data/test_logits_hw.bin"
mode=${1:---load-only}

case "${mode}" in
    --load-only|--probe-only|--read-one|--id-only|--first-image-only|--stress-resident|--mnist-10000|--full)
        ;;
    *)
        echo "Usage: sudo $0 [--load-only|--probe-only|--read-one|--id-only|--first-image-only|--stress-resident|--mnist-10000|--full]" >&2
        exit 2
        ;;
esac

if [[ ${EUID} -ne 0 ]]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

for file in \
    "${firmware_dir}/lenet5_kv260.bit.bin" \
    "${firmware_dir}/lenet5_kv260.dtbo" \
    "${module_path}" \
    "${test_path}" \
    "${weight_path}" \
    "${param_path}" \
    "${image_path}" \
    "${label_path}" \
    "${golden_logit_path}"; do
    if [[ ! -f "${file}" ]]; then
        echo "Missing required file: ${file}" >&2
        exit 1
    fi
done

if [[ ${mode} == --read-one || ${mode} == --id-only ||
      ${mode} == --first-image-only || ${mode} == --stress-resident ||
      ${mode} == --mnist-10000 ]]; then
    if [[ ! -e /dev/lenet5_board ]]; then
        echo "/dev/lenet5_board is absent; run --probe-only first" >&2
        exit 1
    fi
fi

if [[ ${mode} == --read-one ]]; then
    "${test_path}" --read-one accel 0x0
    echo "STAGE04_READ_ONE_PASS"
    exit 0
fi

if [[ ${mode} == --id-only ]]; then
    "${test_path}" --id-only
    echo "STAGE04_ID_ONLY_PASS"
    exit 0
fi

if [[ ${mode} == --first-image-only ]]; then
    "${test_path}" \
        "${weight_path}" \
        "${param_path}" \
        "${image_path}" 0
    echo "STAGE04_FIRST_IMAGE_ONLY_PASS"
    exit 0
fi

if [[ ${mode} == --stress-resident ]]; then
    "${test_path}" --stress-resident 100 \
        "${weight_path}" \
        "${param_path}" \
        "${image_path}"
    echo "STAGE04_RESIDENT_STRESS_PASS"
    exit 0
fi

if [[ ${mode} == --mnist-10000 ]]; then
    "${test_path}" --dataset 10000 \
        "${weight_path}" \
        "${param_path}" \
        "${image_path}" \
        "${label_path}" \
        "${golden_logit_path}"
    echo "STAGE04_MNIST_10000_PASS"
    exit 0
fi

if [[ ${mode} == --probe-only ]]; then
    if [[ $(cat /sys/class/fpga_manager/fpga0/state) != operating ]]; then
        echo "FPGA manager is not operating; run --load-only first" >&2
        exit 1
    fi
    if lsmod | grep -q '^lenet5_board '; then
        rmmod lenet5_board
    fi
    insmod "${module_path}"
    if [[ ! -e /dev/lenet5_board ]]; then
        echo "/dev/lenet5_board was not created" >&2
        dmesg | tail -n 80
        exit 1
    fi
    chmod 0660 /dev/lenet5_board
    device_group=kvm
    if [[ -n ${SUDO_USER:-} && ${SUDO_USER} != root ]]; then
        device_group=$(id -gn "${SUDO_USER}")
    fi
    chgrp "${device_group}" /dev/lenet5_board
    echo "STAGE04_DRIVER_PROBE_PASS"
    exit 0
fi

if lsmod | grep -q '^lenet5_board '; then
    rmmod lenet5_board
fi

if [[ -d /sys/kernel/config/device-tree/overlays/Full ]]; then
    fpgautil -R -n Full
fi

if compgen -G \
        '/sys/kernel/config/device-tree/overlays/k26-starter-kits_image_*' \
        >/dev/null; then
    xmutil unloadapp
fi

fpgautil \
    -b "${firmware_dir}/lenet5_kv260.bit.bin" \
    -o "${firmware_dir}/lenet5_kv260.dtbo" \
    -f Full -n Full

if [[ $(cat /sys/class/fpga_manager/fpga0/state) != operating ]]; then
    echo "FPGA manager did not enter operating state" >&2
    exit 1
fi

if [[ ${mode} == --load-only ]]; then
    echo "STAGE04_FPGA_LOAD_PASS"
    exit 0
fi

insmod "${module_path}"

if [[ ! -e /dev/lenet5_board ]]; then
    echo "/dev/lenet5_board was not created" >&2
    dmesg | tail -n 80
    exit 1
fi

chmod 0660 /dev/lenet5_board
device_group=kvm
if [[ -n ${SUDO_USER:-} && ${SUDO_USER} != root ]]; then
    device_group=$(id -gn "${SUDO_USER}")
fi
chgrp "${device_group}" /dev/lenet5_board

"${test_path}" --id-only
"${test_path}" \
    "${weight_path}" \
    "${param_path}" \
    "${image_path}" 0

echo "STAGE04_INSTALL_AND_FIRST_IMAGE_PASS"
