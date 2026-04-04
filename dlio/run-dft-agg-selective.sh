#!/bin/bash

set -euo pipefail

SOURCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

export APP_ID=dft-agg-selective
export JOB_NAME="dlio-$APP_ID"
export DFTRACER_ENABLE=1
export DFTRACER_ENABLE_AGGREGATION=1
export DFTRACER_AGGREGATION_TYPE=SELECTIVE
export DFTRACER_AGGREGATION_FILE="${SOURCE_DIR}/agg-rules.yaml"
export DFTRACER_TRACE_INTERVAL_MS=1000

bash "${SOURCE_DIR}/run.sh"
