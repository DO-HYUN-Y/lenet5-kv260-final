#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
software_dir=$(cd "${script_dir}/.." && pwd)
firmware_dir="${software_dir}/build/firmware"
module_path="${software_dir}/driver/alexnet_board.ko"
bitstream_path="${firmware_dir}/alexnet_m4n8_kv260.bit.bin"
overlay_path="${firmware_dir}/alexnet_m4n8_kv260.dtbo"
mode=${1:---load-and-probe}

bitstream_sha256=7b0884f1875602942752b69fd203b105f32b2193ce82df87a47e9c3bd337c3ae
overlay_sha256=d33ca5572e3f746a18ce80e6e2c01e827a0ca058d11b37a5603973bd32c433e8

case "${mode}" in
    --load-only|--probe-only|--load-and-probe)
        ;;
    *)
        echo "Usage: sudo $0 [--load-only|--probe-only|--load-and-probe]" >&2
        exit 2
        ;;
esac

if [[ ${EUID} -ne 0 ]]; then
    echo "Run with sudo: sudo $0 ${mode}" >&2
    exit 1
fi

for required in "${bitstream_path}" "${overlay_path}" "${module_path}"; do
    if [[ ! -f ${required} ]]; then
        echo "Missing required file: ${required}" >&2
        exit 1
    fi
done

printf '%s  %s\n' "${bitstream_sha256}" "${bitstream_path}" | sha256sum -c -
printf '%s  %s\n' "${overlay_sha256}" "${overlay_path}" | sha256sum -c -

load_fpga() {
    if lsmod | grep -q '^alexnet_board '; then
        rmmod alexnet_board
    fi

    if [[ -d /sys/kernel/config/device-tree/overlays/Full ]]; then
        fpgautil -R -n Full
    fi

    if compgen -G \
            '/sys/kernel/config/device-tree/overlays/k26-starter-kits_image_*' \
            >/dev/null; then
        xmutil unloadapp
    fi

    fpgautil -b "${bitstream_path}" -o "${overlay_path}" -f Full -n Full

    if [[ $(cat /sys/class/fpga_manager/fpga0/state) != operating ]]; then
        echo "FPGA manager did not enter operating state" >&2
        exit 1
    fi
    if [[ ! -r /sys/kernel/config/device-tree/overlays/Full/status ]] ||
            [[ $(tr -d '\000' </sys/kernel/config/device-tree/overlays/Full/status) != applied ]]; then
        echo "AlexNet device-tree overlay is not applied" >&2
        exit 1
    fi
    echo "ALEXNET_KV260_FPGA_LOAD_PASS"
}

probe_driver() {
    if [[ $(cat /sys/class/fpga_manager/fpga0/state) != operating ]]; then
        echo "FPGA manager is not operating; run --load-only first" >&2
        exit 1
    fi
    if [[ ! -r /sys/kernel/config/device-tree/overlays/Full/status ]] ||
            [[ $(tr -d '\000' </sys/kernel/config/device-tree/overlays/Full/status) != applied ]]; then
        echo "AlexNet overlay is absent; run --load-only first" >&2
        exit 1
    fi

    if lsmod | grep -q '^alexnet_board '; then
        rmmod alexnet_board
    fi
    insmod "${module_path}"

    if [[ ! -e /dev/alexnet_board ]]; then
        echo "/dev/alexnet_board was not created" >&2
        dmesg | tail -n 80
        exit 1
    fi

    device_group=root
    if [[ -n ${SUDO_USER:-} && ${SUDO_USER} != root ]]; then
        device_group=$(id -gn "${SUDO_USER}")
    fi
    chgrp "${device_group}" /dev/alexnet_board
    chmod 0660 /dev/alexnet_board
    dmesg | tail -n 30 | grep -E 'alexnet|fpga' || true
    echo "ALEXNET_KV260_DRIVER_PROBE_PASS"
}

case "${mode}" in
    --load-only)
        load_fpga
        ;;
    --probe-only)
        probe_driver
        ;;
    --load-and-probe)
        load_fpga
        probe_driver
        ;;
esac
