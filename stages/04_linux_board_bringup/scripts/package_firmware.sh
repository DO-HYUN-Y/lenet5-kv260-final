#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
stage_dir=$(cd "${script_dir}/.." && pwd)
project_dir=$(cd "${stage_dir}/../.." && pwd)
stage05_bit="${project_dir}/stages/05_pl_clock_150mhz/build/output/lenet5_kv260.bit"
build_dir="${stage_dir}/build/firmware"
bootgen_bin=${BOOTGEN:-/tools/Xilinx/2025.1/Vitis/bin/bootgen}

if [[ ! -f "${stage05_bit}" ]]; then
    echo "Missing Stage05 bitstream: ${stage05_bit}" >&2
    exit 1
fi
if [[ ! -x "${bootgen_bin}" ]]; then
    echo "bootgen is unavailable: ${bootgen_bin}" >&2
    exit 1
fi
if ! command -v dtc >/dev/null 2>&1; then
    echo "dtc is unavailable" >&2
    exit 1
fi

mkdir -p "${build_dir}"
cp "${stage05_bit}" "${build_dir}/lenet5_kv260.bit"
cp "${stage_dir}/firmware/lenet5_kv260.bif" "${build_dir}/lenet5_kv260.bif"

(
    cd "${build_dir}"
    "${bootgen_bin}" -image lenet5_kv260.bif -arch zynqmp -w on \
        -process_bitstream bin
)

dtc -@ -I dts -O dtb \
    -o "${build_dir}/lenet5_kv260.dtbo" \
    "${stage_dir}/overlay/lenet5_kv260.dts"

if [[ ! -s "${build_dir}/lenet5_kv260.bit.bin" ]]; then
    echo "bootgen did not create lenet5_kv260.bit.bin" >&2
    exit 1
fi
if [[ ! -s "${build_dir}/lenet5_kv260.dtbo" ]]; then
    echo "dtc did not create lenet5_kv260.dtbo" >&2
    exit 1
fi

roundtrip_warnings="${build_dir}/lenet5_kv260.roundtrip.warnings"
dtc -I dtb -O dts "${build_dir}/lenet5_kv260.dtbo" \
    > "${build_dir}/lenet5_kv260.roundtrip.dts" \
    2> "${roundtrip_warnings}"

# An unresolved external clock phandle is normal in a standalone plugin
# overlay. Any other round-trip warning is treated as a packaging failure.
if grep -v -E 'Warning \(clocks_property\): .*Could not get phandle node' \
        "${roundtrip_warnings}" | grep -q .; then
    cat "${roundtrip_warnings}" >&2
    echo "Unexpected DTBO round-trip warning" >&2
    exit 1
fi

sha256sum \
    "${build_dir}/lenet5_kv260.bit.bin" \
    "${build_dir}/lenet5_kv260.dtbo"

echo "STAGE04_FIRMWARE_PACKAGE_PASS"
