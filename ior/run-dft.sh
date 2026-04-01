#!/bin/bash

set -euo pipefail

SOURCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

export APP_ID=dft
export JOB_NAME="ior-$APP_ID"
export DFTRACER_ENABLE=1

bash "${SOURCE_DIR}/run.sh"
