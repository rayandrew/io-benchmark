#!/bin/bash
set -e

PREFIX=/p/lustre5/$USER/stack/ior
# PREFIX=/usr/WS2/$USER/io-benchmark/ior

ml load gcc-native/12.1
ml load python/3.11
ml load cmake/3.29.2

if [ ! -f "$PREFIX/.venv/bin/activate" ]; then
  echo "==> Haven't set up the environment yet. Please run install.sh first."
  exit 1
fi

echo "==> Activating existing virtual environment..."
source "$PREFIX/.venv/bin/activate"

export PATH="$PREFIX/ior-install/bin:$PREFIX/dftracer/bin:$PATH"
YAML_CPP_LIB=/usr/tce/packages/python/python-3.11.5/lib
export LD_LIBRARY_PATH="$PREFIX/dftracer/lib:$PREFIX/dftracer/lib64:$YAML_CPP_LIB:$LD_LIBRARY_PATH"

ts=$(date +%Y%m%d-%H%M%S)
APP_ID="${APP_ID:-"no-dft"}"
EXP_NAME="${EXP_NAME:-"mpiio-write"}"
BASE_OUTPUT_DIR="/p/lustre5/$USER/stack/ior/results/$EXP_NAME/$APP_ID/$ts"
FILES_DIR="$BASE_OUTPUT_DIR/files"
TRACES_DIR="$BASE_OUTPUT_DIR/traces"
mkdir -p "$FILES_DIR"
mkdir -p "$TRACES_DIR"

export DFTRACER_LOG_FILE="$TRACES_DIR/trace"
export DFTRACER_LD_PRELOAD="$PREFIX/dftracer/lib64/libdftracer_preload.so"

export DFTRACER_ENABLE=${DFTRACER_ENABLE:-0}
export DFTRACER_INIT=PRELOAD
export DFTRACER_DATA_DIR="all"
export DFTRACER_INC_METADATA=${DFTRACER_INC_METADATA:-1}
export DFTRACER_TRACE_COMPRESSION=${DFTRACER_TRACE_COMPRESSION:-1}
export DFTRACER_ENABLE_AGGREGATION=${DFTRACER_ENABLE_AGGREGATION:-0}
export DFTRACER_AGGREGATION_TYPE=${DFTRACER_AGGREGATION_TYPE:-FULL}
export DFTRACER_TRACE_INTERVAL_MS=${DFTRACER_TRACE_INTERVAL_MS:-1000}
export DFTRACER_AGGREGATION_FILE=${DFTRACER_AGGREGATION_FILE:-}

export NUM_NODES=${NUM_NODES:-8}
export PPN=${PPN:-64}
export NUM_PROCS=$((NUM_NODES * PPN))

# IOR MPI-IO write parameters
TRANSFER_SIZE=${TRANSFER_SIZE:-1m}
BLOCK_SIZE=${BLOCK_SIZE:-32m}
REPETITIONS=${REPETITIONS:-5}
FILE_PER_PROC=${FILE_PER_PROC:-1}

IOR_ARGS=(
  -a MPIIO
  -w
  -t "$TRANSFER_SIZE"
  -b "$BLOCK_SIZE"
  -i "$REPETITIONS"
  -e                      # fsync after write
  -k                      # keep files after test
  -o "$FILES_DIR/testfile"
)

if [ "$FILE_PER_PROC" -eq 1 ]; then
  IOR_ARGS+=(-F)
fi

echo "Benchmark configuration:"
echo "========================"
echo "DFTracer enabled: $DFTRACER_ENABLE"
if [ "$DFTRACER_ENABLE" -eq 1 ]; then
  echo "  DFTracer log file: $DFTRACER_LOG_FILE"
  echo "  DFTracer data directory: $DFTRACER_DATA_DIR"
  echo "  DFTracer include metadata: $DFTRACER_INC_METADATA"
  echo "  DFTracer trace compression: $DFTRACER_TRACE_COMPRESSION"
  echo "  DFTracer enable aggregation: $DFTRACER_ENABLE_AGGREGATION"
  if [ "$DFTRACER_ENABLE_AGGREGATION" -eq 1 ]; then
    echo "  DFTracer aggregation type: $DFTRACER_AGGREGATION_TYPE"
    echo "  DFTracer trace interval (ms): $DFTRACER_TRACE_INTERVAL_MS"
    echo "  DFTracer aggregation file: $DFTRACER_AGGREGATION_FILE"
  fi
else
  echo "  DFTracer is disabled. No traces will be collected."
fi
echo "Number of nodes: $NUM_NODES"
echo "Processes per node: $PPN"
echo "Total number of processes: $NUM_PROCS"
echo "IOR API: MPIIO"
echo "Transfer size: $TRANSFER_SIZE"
echo "Block size: $BLOCK_SIZE"
echo "Repetitions: $REPETITIONS"
echo "File per process: $FILE_PER_PROC"
echo "Base output directory: $BASE_OUTPUT_DIR"
echo "Files directory: $FILES_DIR"
echo "Traces directory: $TRACES_DIR"
echo "========================"

env > "$BASE_OUTPUT_DIR/env.txt"

ldd $PREFIX/ior-install/bin/ior > "$BASE_OUTPUT_DIR/ldd_ior.txt" 2>&1

ulimit -c unlimited

if [[ "$DFTRACER_ENABLE" -eq 1 ]]; then
  echo "DFTracer is enabled. Traces will be saved to: $TRACES_DIR"
  flux run -N $NUM_NODES -n $NUM_PROCS \
      --exclusive -o fastload=on \
      --env=DFTRACER_ENABLE="${DFTRACER_ENABLE}" \
      --env=DFTRACER_INIT="${DFTRACER_INIT}" \
      --env=DFTRACER_DATA_DIR="${DFTRACER_DATA_DIR}" \
      --env=DFTRACER_INC_METADATA="${DFTRACER_INC_METADATA}" \
      --env=DFTRACER_LOG_FILE="${DFTRACER_LOG_FILE}" \
      --env=LD_PRELOAD="${DFTRACER_LD_PRELOAD}" \
      $PREFIX/ior-install/bin/ior "${IOR_ARGS[@]}" 2>&1 | tee "$BASE_OUTPUT_DIR/log.txt"
else
  echo "DFTracer is disabled. No traces will be collected."
  flux run -N $NUM_NODES -n $NUM_PROCS \
      --exclusive -o fastload=on \
      $PREFIX/ior-install/bin/ior "${IOR_ARGS[@]}" 2>&1 | tee "$BASE_OUTPUT_DIR/log.txt"
fi
