#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
stage_dir=$(cd "${script_dir}/.." && pwd)
board=${LENET5_BOARD:-ubuntu@192.168.0.74}
remote_dir=${LENET5_STAGE06_REMOTE_DIR:-/home/ubuntu/lenet5_stage06}
stage04_dir=${LENET5_STAGE04_REMOTE_DIR:-/home/ubuntu/lenet5_stage04}
count=${1:-10000}
log_dir="${stage_dir}/build"
log_path="${log_dir}/persistent_${count}_board.log"

if [[ ! ${count} =~ ^[0-9]+$ ]] ||
        ((count < 1 || count > 10000)); then
    echo "COUNT must be 1..10000" >&2
    exit 2
fi

mkdir -p "${log_dir}"
ssh -o BatchMode=yes -o ConnectTimeout=5 "${board}" \
    "'${remote_dir}/software/lenet5_persistent_runtime' '${count}' \
     '${stage04_dir}/data/weights_hw.bin' \
     '${stage04_dir}/data/params_hw.bin' \
     '${stage04_dir}/data/test_images.bin' \
     '${stage04_dir}/data/test_labels.bin' \
     '${stage04_dir}/data/test_logits_hw.bin'" |
    tee "${log_path}"

grep -q "LENET5_PERSISTENT_RUNTIME_PASS images=${count}" "${log_path}"
echo "STAGE06_BOARD_PASS count=${count} log=${log_path}"
