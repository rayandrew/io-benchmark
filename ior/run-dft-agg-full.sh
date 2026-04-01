#!/bin/bash

set -euo pipefail

SOURCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

export APP_ID=dft-agg-full
export JOB_NAME="ior-$APP_ID"
export DFTRACER_ENABLE=1
export DFTRACER_ENABLE_AGGREGATION=1
export DFTRACER_AGGREGATION_TYPE=FULL
export DFTRACER_TRACE_INTERVAL_MS=5000

bash "${SOURCE_DIR}/run.sh"