#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
stage_dir=$(cd "${script_dir}/.." && pwd)
build_dir="${stage_dir}/build"
firmware_dir="${build_dir}/firmware"
module_path="${stage_dir}/driver/lenet5_board.ko"
kernel_release=$(uname -r)

for tool in dtc fdtoverlay fdtget modinfo; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "Missing required tool: ${tool}" >&2
        exit 1
    fi
done

vermagic=$(modinfo -F vermagic "${module_path}")
if [[ ${vermagic} != "${kernel_release} "* ]]; then
    echo "Kernel module vermagic mismatch: ${vermagic}" >&2
    exit 1
fi

dtc -I fs -O dtb \
    -o "${build_dir}/base-active.dtb" \
    /sys/firmware/devicetree/base \
    2> "${build_dir}/base-active.warnings"
fdtoverlay \
    -i "${build_dir}/base-active.dtb" \
    -o "${build_dir}/merged-check.dtb" \
    "${firmware_dir}/lenet5_kv260.dtbo"

node=/axi/lenet5@a0000000
firmware_name=$(fdtget -t s "${build_dir}/merged-check.dtb" \
    /fpga-full firmware-name)
compatible=$(fdtget -t s "${build_dir}/merged-check.dtb" \
    "${node}" compatible)
clock_names=$(fdtget -t s "${build_dir}/merged-check.dtb" \
    "${node}" clock-names)
fabric_clock_hz=$(fdtget -t u "${build_dir}/merged-check.dtb" \
    "${node}" yun,fabric-clock-hz)
reg=$(fdtget -t x "${build_dir}/merged-check.dtb" "${node}" reg)

[[ ${firmware_name} == lenet5_kv260.bit.bin ]]
[[ ${compatible} == yun,lenet5-kv260-board-1.1 ]]
[[ ${clock_names} == "pl_clk0" ]]
[[ ${fabric_clock_hz} == 149998501 ]]
[[ ${reg} == "0 a0000000 0 10000 0 a0010000 0 10000" ]]

# HP0 is non-coherent. Presence of this property would make the Linux DMA
# layer apply the wrong cache-coherency policy.
if fdtget "${build_dir}/merged-check.dtb" "${node}" dma-coherent \
        >/dev/null 2>&1; then
    echo "Invalid dma-coherent property on non-coherent HP0 path" >&2
    exit 1
fi

printf 'KERNEL_RELEASE=%s\n' "${kernel_release}"
printf 'MODULE_VERMAGIC=%s\n' "${vermagic}"
printf 'OVERLAY_NODE=%s\n' "${node}"
printf 'OVERLAY_REG=%s\n' "${reg}"
printf 'OVERLAY_CLOCK_NAMES=%s\n' "${clock_names}"
printf 'OVERLAY_FABRIC_CLOCK_HZ=%s\n' "${fabric_clock_hz}"
sha256sum \
    "${firmware_dir}/lenet5_kv260.bit.bin" \
    "${firmware_dir}/lenet5_kv260.dtbo"
echo "STAGE04_BOARD_STATIC_VALIDATE_PASS"
