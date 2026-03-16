#!/bin/bash
set -e

PREFIX=/p/lustre5/$USER/stack/h5bench
# PREFIX=/usr/WS2/$USER/io-benchmark/h5bench

ml load gcc-native/12.1
ml load python/3.11
ml load cmake/3.29.2
ml load mpifileutils

if [ ! -f "$PREFIX/.venv/bin/activate" ]; then
  echo "==> Creating new virtual environment..."
  python3 -m venv "$PREFIX/.venv"
fi

echo "==> Activating existing virtual environment..."
source "$PREFIX/.venv/bin/activate"

export PATH="$PREFIX/h5bench-install/bin:$PREFIX/hdf5/bin:$PREFIX/dftracer/bin:$PATH"
YAML_CPP_LIB=/usr/tce/packages/python/python-3.11.5/lib
export LD_LIBRARY_PATH="$PREFIX/vol-async/lib:$PREFIX/hdf5/lib:$PREFIX/argobots/lib:$PREFIX/dftracer/lib:$PREFIX/dftracer/lib64:$YAML_CPP_LIB:$LD_LIBRARY_PATH"
export HDF5_DIR="$PREFIX/hdf5"
export HDF5_PLUGIN_PATH="$PREFIX/vol-async/lib"
export HDF5_VOL_CONNECTOR="async under_vol=0;under_info={}"

ts=$(date +%Y%m%d-%H%M%S)
BASE_OUTPUT_DIR="/p/lustre5/sinurat1/stack/h5bench/results/async-write-3d-contig-contig-$ts"
FILES_DIR="$BASE_OUTPUT_DIR/files"
TRACES_DIR="$BASE_OUTPUT_DIR/traces"
mkdir -p "$FILES_DIR"
mkdir -p "$TRACES_DIR"

# h5bench async-write-3d-contig-contig.json
export DFTRACER_ENABLE=1
export DFTRACER_INIT=PRELOAD
export DFTRACER_DATA_DIR="all"
export DFTRACER_INC_METADATA=1
export DFTRACER_LOG_FILE="$TRACES_DIR/trace"
export DFTRACER_LD_PRELOAD="$PREFIX/dftracer/lib64/libdftracer_preload.so"

export NUM_NODES=${NUM_NODES:-8}
export PPN=${PPN:-64}
export NUM_PROCS=$((NUM_NODES * PPN))

# LD_PRELOAD="$LD_PRELOAD" \
# /p/lustre5/sinurat1/stack/h5bench/h5bench-install/bin/h5bench_write \
#     /usr/workspace/sinurat1/io-benchmark/h5bench/async-write-3d-contig-contig.cfg \
#     $FILES_DIR/test.hdf5 2>&1 | tee "$OUTPUT_DIR/log.txt"

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

# DIM_1=16384
# DIM_2=1024
# DIM_3=1

flux run -N $NUM_NODES -n $NUM_PROCS \
    --time-limit=1h \
    --queue=pdebug \
    --env DFTRACER_ENABLE=$DFTRACER_ENABLE \
    --env DFTRACER_INIT=$DFTRACER_INIT \
    --env DFTRACER_DATA_DIR=$DFTRACER_DATA_DIR \
    --env DFTRACER_INC_METADATA=$DFTRACER_INC_METADATA \
    --env DFTRACER_LOG_FILE=$DFTRACER_LOG_FILE \
    --env LD_PRELOAD=$DFTRACER_LD_PRELOAD \
    $PREFIX/h5bench-install/bin/h5bench_write \
        $BASE_OUTPUT_DIR/benchmark.cfg \
        $FILES_DIR/test.hdf5 2>&1 | tee "$BASE_OUTPUT_DIR/log.txt"

