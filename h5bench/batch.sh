#!/bin/bash
set -e

PREFIX=/p/lustre5/$USER/stack/h5bench
# PREFIX=/usr/WS2/$USER/io-benchmark/h5bench

ml load gcc-native/12.1
ml load python/3.11
ml load cmake/3.29.2
# ml load mpifileutils

if [ ! -f "$PREFIX/.venv/bin/activate" ]; then
  echo "==> Haven't set up the environment yet. Please run install.sh first."
  exit 1
fi

echo "==> Activating existing virtual environment..."
source "$PREFIX/.venv/bin/activate"

export PATH="$PREFIX/h5bench-install/bin:$PREFIX/hdf5/bin:$PREFIX/dftracer/bin:$PATH"
YAML_CPP_LIB=/usr/tce/packages/python/python-3.11.5/lib
export LD_LIBRARY_PATH="$PREFIX/vol-async/lib:$PREFIX/hdf5/lib:$PREFIX/argobots/lib:$PREFIX/dftracer/lib:$PREFIX/dftracer/lib64:$YAML_CPP_LIB:$LD_LIBRARY_PATH"
export HDF5_DIR="$PREFIX/hdf5"
export HDF5_PLUGIN_PATH="$PREFIX/vol-async/lib"

export ASYNC_VOL_ENABLE=${ASYNC_VOL_ENABLE:-1}

if [ "$ASYNC_VOL_ENABLE" -eq 1 ]; then
  export HDF5_VOL_CONNECTOR="async under_vol=0;under_info={}"
  EXP_NAME=${EXP_NAME:-"async-write-3d-contig-contig"}
else
  export HDF5_VOL_CONNECTOR=""
  EXP_NAME=${EXP_NAME:-"sync-write-3d-contig-contig"}
fi

ts=$(date +%Y%m%d-%H%M%S)
APP_ID="${APP_ID:-"no-dft"}"
EXP_NAME="$EXP_NAME"
BASE_OUTPUT_DIR="/p/lustre5/sinurat1/stack/h5bench/results/$EXP_NAME/$APP_ID/$ts"
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

# export TIME_LIMIT=${TIME_LIMIT:-1h}
# export QUEUE=${QUEUE:-pdebug}

cat << EOF > "$BASE_OUTPUT_DIR/benchmark.cfg"
MEM_PATTERN=CONTIG
FILE_PATTERN=CONTIG
TIMESTEPS=5
DELAYED_CLOSE_TIMESTEPS=2
COLLECTIVE_DATA=YES
COLLECTIVE_METADATA=YES
EMULATED_COMPUTE_TIME_PER_TIMESTEP=1 s
NUM_DIMS=3
DIM_1=256
DIM_2=128
DIM_3=128
FILE_PER_PROC=Y
CSV_FILE=$BASE_OUTPUT_DIR/output.csv
EOF

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
echo "Async VOL enabled: $ASYNC_VOL_ENABLE"
echo "HDF5 VOL connector: $HDF5_VOL_CONNECTOR"
echo "Number of nodes: $NUM_NODES"
echo "Processes per node: $PPN"
echo "Total number of processes: $NUM_PROCS"
echo "Base output directory: $BASE_OUTPUT_DIR"
echo "Files directory: $FILES_DIR"
echo "Traces directory: $TRACES_DIR"
echo "========================"

# cat << EOF > "$BASE_OUTPUT_DIR/benchmark.cfg"
# MEM_PATTERN=CONTIG
# FILE_PATTERN=INTERLEAVED
# TIMESTEPS=5
# DELAYED_CLOSE_TIMESTEPS=2
# COLLECTIVE_DATA=YES
# COLLECTIVE_METADATA=YES
# EMULATED_COMPUTE_TIME_PER_TIMESTEP=1 s
# NUM_DIMS=2
# DIM_1=512
# DIM_2=512
# DIM_3=1
# FILE_PER_PROC=Y
# CSV_FILE=$BASE_OUTPUT_DIR/output.csv
# EOF

env > "$BASE_OUTPUT_DIR/env.txt"

ldd $PREFIX/h5bench-install/bin/h5bench_write > "$BASE_OUTPUT_DIR/ldd_h5bench_write.txt" 2>&1

# $PREFIX/h5bench-install/bin/h5bench_write \
#           $BASE_OUTPUT_DIR/benchmark.cfg \
#           $FILES_DIR/test.hdf5 2>&1 | tee "$BASE_OUTPUT_DIR/log.txt"

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
      $PREFIX/h5bench-install/bin/h5bench_write \
          $BASE_OUTPUT_DIR/benchmark.cfg \
          $FILES_DIR/test.hdf5 2>&1 | tee "$BASE_OUTPUT_DIR/log.txt"
else
  echo "DFTracer is disabled. No traces will be collected."
  flux run -N $NUM_NODES -n $NUM_PROCS \
      --exclusive -o fastload=on \
      $PREFIX/h5bench-install/bin/h5bench_write \
          $BASE_OUTPUT_DIR/benchmark.cfg \
          $FILES_DIR/test.hdf5 2>&1 | tee "$BASE_OUTPUT_DIR/log.txt"
fi

