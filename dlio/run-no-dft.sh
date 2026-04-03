#!/bin/bash

set -euo pipefail

SOURCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

export APP_ID=no-dft
export JOB_NAME="dlio-$APP_ID"
export DFTRACER_ENABLE=0

bash "${SOURCE_DIR}/run.sh"
