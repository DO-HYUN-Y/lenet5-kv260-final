#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
stage_dir=$(cd "${script_dir}/.." && pwd)
board=${LENET5_BOARD:-ubuntu@192.168.0.74}
remote_dir=${LENET5_STAGE06_REMOTE_DIR:-/home/ubuntu/lenet5_stage06}
uapi_dir=/home/ubuntu/lenet5_stage04/driver

ssh -o BatchMode=yes "${board}" \
    "mkdir -p '${remote_dir}/software'"
scp -q \
    "${stage_dir}/software/lenet5_persistent_runtime.c" \
    "${stage_dir}/software/Makefile" \
    "${board}:${remote_dir}/software/"
ssh -o BatchMode=yes "${board}" \
    "make -C '${remote_dir}/software' clean all UAPI_DIR='${uapi_dir}'"

echo "STAGE06_DEPLOY_PASS remote=${board}:${remote_dir}"
