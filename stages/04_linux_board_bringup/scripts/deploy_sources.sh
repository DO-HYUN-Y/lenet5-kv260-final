#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
stage_dir=$(cd "${script_dir}/.." && pwd)
project_dir=$(cd "${stage_dir}/../.." && pwd)
board=${LENET5_BOARD:-ubuntu@192.168.0.74}
remote_dir=${LENET5_REMOTE_DIR:-/home/ubuntu/lenet5_stage04}

"${script_dir}/package_firmware.sh"

ssh -o BatchMode=yes "${board}" \
    "mkdir -p '${remote_dir}/driver' '${remote_dir}/software' \
        '${remote_dir}/scripts' '${remote_dir}/build/firmware' \
        '${remote_dir}/data'"

scp -q \
    "${stage_dir}/driver/lenet5_board.c" \
    "${stage_dir}/driver/lenet5_board_uapi.h" \
    "${stage_dir}/driver/Makefile" \
    "${board}:${remote_dir}/driver/"
scp -q \
    "${stage_dir}/software/lenet5_board_test.c" \
    "${stage_dir}/software/Makefile" \
    "${board}:${remote_dir}/software/"
scp -q \
    "${stage_dir}/scripts/install_and_id_test.sh" \
    "${stage_dir}/scripts/validate_board_build.sh" \
    "${board}:${remote_dir}/scripts/"
scp -q \
    "${stage_dir}/build/firmware/lenet5_kv260.bit.bin" \
    "${stage_dir}/build/firmware/lenet5_kv260.dtbo" \
    "${board}:${remote_dir}/build/firmware/"
scp -q \
    "${project_dir}/output/weights_hw.bin" \
    "${project_dir}/output/params_hw.bin" \
    "${project_dir}/output/test_images.bin" \
    "${project_dir}/output/test_labels.bin" \
    "${project_dir}/output/test_logits_hw.bin" \
    "${board}:${remote_dir}/data/"

ssh -o BatchMode=yes "${board}" \
    "chmod +x '${remote_dir}/scripts/install_and_id_test.sh' \
        '${remote_dir}/scripts/validate_board_build.sh' && \
     make -C '${remote_dir}/software' clean all && \
     make -C '${remote_dir}/driver' clean all && \
     '${remote_dir}/scripts/validate_board_build.sh'"

echo "STAGE04_BOARD_BUILD_PASS remote=${board}:${remote_dir}"
