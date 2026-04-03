#!/bin/bash

set -euo pipefail

SOURCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

export APP_ID=${APP_ID:-generate}
export JOB_NAME=${JOB_NAME:-"dlio-${APP_ID}"}
export NUM_NODES=2
export PPN=64
export DLIO_GENERATE_DATA=1
export DLIO_TRAIN=0
export DLIO_CHECKPOINT=0
export DLIO_EVAL=0
export EXP_NAME=${EXP_NAME:-"${DLIO_WORKLOAD:-unet3d_h100}-generate"}

bash "${SOURCE_DIR}/run.sh"
