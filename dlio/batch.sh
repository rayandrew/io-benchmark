#!/bin/bash
set -euo pipefail

PREFIX=/p/lustre5/$USER/stack/dlio
DLIO_SRC_DIR=${DLIO_SRC_DIR:-$PREFIX/dlio_benchmark-src}
ROCM_VERSION=${ROCM_VERSION:-7.1.1}
GCC_VERSION=${GCC_VERSION:-12.1}
PY_VERSION=${PY_VERSION:-3.11}

# Reinitialize modules for batch shells that do not source them by default.
source /etc/profile.d/z00_lmod.sh
module use /opt/toss/modules/modulefiles/

ml load rocm/$ROCM_VERSION
ml load rccl
ml load ninja
ml load gcc-native/$GCC_VERSION
ml load python/$PY_VERSION
ml load cmake/3.29.2

if [ ! -f "$PREFIX/.venv/bin/activate" ]; then
  echo "==> Haven't set up the environment yet. Please run install.sh first."
  exit 1
fi

if [ ! -d "$DLIO_SRC_DIR" ]; then
  echo "==> DLIO source tree not found at $DLIO_SRC_DIR"
  exit 1
fi

echo "==> Activating existing virtual environment..."
source "$PREFIX/.venv/bin/activate"

filter_colon_path() {
  local input="$1"
  local output=""
  local entry=""
  IFS=':' read -r -a parts <<< "$input"
  for entry in "${parts[@]}"; do
    if [[ "$entry" == *"/collab/usr/gapps/python/"*"/anaconda3-2023.09"* ]]; then
      continue
    fi
    if [ -z "$entry" ]; then
      continue
    fi
    if [ -z "$output" ]; then
      output="$entry"
    else
      output="$output:$entry"
    fi
  done
  printf '%s\n' "$output"
}

export PATH="$(filter_colon_path "${PATH:-}")"
export LD_LIBRARY_PATH="$(filter_colon_path "${LD_LIBRARY_PATH:-}")"

export ROCM_HOME="${ROCM_PATH:-/opt/rocm-${ROCM_VERSION}}"
export PATH="$ROCM_HOME/bin:$PREFIX/dftracer/bin:$PATH"
export CPATH="$ROCM_HOME/include:${CPATH:-}"
export DYLD_LIBRARY_PATH="$ROCM_HOME/lib:${DYLD_LIBRARY_PATH:-}"

export CC="$(which mpicc)"
export CXX="$(which mpic++)"
export CMAKE_C_COMPILER="$(which mpicc)"
export CMAKE_CXX_COMPILER="$(which mpic++)"

DFTRACER_LIB_DIR="$PREFIX/dftracer/lib"
if [ -d "$PREFIX/dftracer/lib64" ]; then
  DFTRACER_LIB_DIR="$PREFIX/dftracer/lib64"
fi

TORCH_LIB_DIR="/p/lustre5/$USER/stack/dlio/.venv/lib/python3.11/site-packages/torch/lib"
export LD_LIBRARY_PATH="$ROCM_HOME/lib:$PREFIX/dftracer/lib:${LD_LIBRARY_PATH:-}"
if [ -d "$TORCH_LIB_DIR" ]; then
  export LD_LIBRARY_PATH="$TORCH_LIB_DIR:$LD_LIBRARY_PATH"
fi

if [ -n "${SYS_TYPE:-}" ]; then
  export LD_LIBRARY_PATH="/collab/usr/global/tools/rccl/${SYS_TYPE}_cray/rocm-${ROCM_VERSION}/install/lib:$LD_LIBRARY_PATH"
fi

export LD_LIBRARY_PATH="/opt/cray/pe/mpich/9.0.1/ofi/CRAYCLANG/20.0/lib:$LD_LIBRARY_PATH"

export NCCL_NET_GDR_LEVEL=${NCCL_NET_GDR_LEVEL:-3}
export FI_CXI_ATS=${FI_CXI_ATS:-0}
export LD_PRELOAD="/lib64/libomp.so:${LD_PRELOAD:-}"

export NUM_NODES=${NUM_NODES:-8}
export PPN=${PPN:-4}
export NUM_PROCS=$((NUM_NODES * PPN))

DLIO_WORKLOAD=${DLIO_WORKLOAD:-unet3d_h100}
DLIO_GENERATE_DATA=${DLIO_GENERATE_DATA:-0}
DLIO_TRAIN=${DLIO_TRAIN:-1}
DLIO_CHECKPOINT=${DLIO_CHECKPOINT:-1}
DLIO_EVAL=${DLIO_EVAL:-0}

WORKLOAD_CONFIG_FILE="$DLIO_SRC_DIR/dlio_benchmark/configs/workload/${DLIO_WORKLOAD}.yaml"
if [ ! -f "$WORKLOAD_CONFIG_FILE" ]; then
  echo "==> Workload config not found: $WORKLOAD_CONFIG_FILE"
  exit 1
fi

BASE_NUM_FILES_TRAIN=$(awk -F': *' '/^[[:space:]]*num_files_train:/ {print $2; exit}' "$WORKLOAD_CONFIG_FILE")
if [ -z "$BASE_NUM_FILES_TRAIN" ]; then
  echo "==> Could not determine dataset.num_files_train from $WORKLOAD_CONFIG_FILE"
  exit 1
fi
# EFFECTIVE_NUM_FILES_TRAIN=$((BASE_NUM_FILES_TRAIN * NUM_NODES))
EFFECTIVE_NUM_FILES_TRAIN=$((BASE_NUM_FILES_TRAIN * NUM_NODES))

to_hydra_bool() {
  if [ "$1" = "1" ]; then
    echo "True"
  else
    echo "False"
  fi
}

ts=$(date +%Y%m%d-%H%M%S)
APP_ID="${APP_ID:-"no-dft"}"
EXP_NAME="${EXP_NAME:-$DLIO_WORKLOAD}"
BASE_OUTPUT_DIR="/p/lustre5/$USER/stack/dlio/results/${EXP_NAME}/${APP_ID}/${ts}"
DATASET_ROOT="$PREFIX/dataset"
DATA_DIR="$DATASET_ROOT/$DLIO_WORKLOAD"
CHECKPOINT_DIR="$BASE_OUTPUT_DIR/checkpoints"
DLIO_OUTPUT_DIR="$BASE_OUTPUT_DIR/output"

export DFTRACER_ENABLE=${DFTRACER_ENABLE:-0}
# export DFTRACER_INIT=INIT
# export DFTRACER_DATA_DIR="all"
export DFTRACER_INC_METADATA=${DFTRACER_INC_METADATA:-1}
export DFTRACER_TRACE_COMPRESSION=${DFTRACER_TRACE_COMPRESSION:-1}
export DFTRACER_ENABLE_AGGREGATION=${DFTRACER_ENABLE_AGGREGATION:-0}
export DFTRACER_AGGREGATION_TYPE=${DFTRACER_AGGREGATION_TYPE:-FULL}
export DFTRACER_TRACE_INTERVAL_MS=${DFTRACER_TRACE_INTERVAL_MS:-1000}
export DFTRACER_AGGREGATION_FILE=${DFTRACER_AGGREGATION_FILE:-}

mkdir -p "$DATASET_ROOT" "$DATA_DIR" "$CHECKPOINT_DIR" "$DLIO_OUTPUT_DIR"
cp "$WORKLOAD_CONFIG_FILE" "$BASE_OUTPUT_DIR/workload.yaml"

export DFTRACER_LD_PRELOAD="$DFTRACER_LIB_DIR/libdftracer_preload.so"

DLIO_ARGS=(
  "workload=$DLIO_WORKLOAD"
  "hydra.run.dir=$DLIO_OUTPUT_DIR"
  "++workload.dataset.data_folder=$DATA_DIR"
  "++workload.dataset.num_files_train=$EFFECTIVE_NUM_FILES_TRAIN"
  "++workload.checkpoint.checkpoint_folder=$CHECKPOINT_DIR"
  "++workload.workflow.generate_data=$(to_hydra_bool "$DLIO_GENERATE_DATA")"
  "++workload.workflow.train=$(to_hydra_bool "$DLIO_TRAIN")"
  "++workload.workflow.checkpoint=$(to_hydra_bool "$DLIO_CHECKPOINT")"
  "++workload.workflow.evaluation=$(to_hydra_bool "$DLIO_EVAL")"
)

echo "Benchmark configuration:"
echo "========================"
echo "DLIO workload: $DLIO_WORKLOAD"
echo "DLIO workload config: $WORKLOAD_CONFIG_FILE"
echo "Base num_files_train: $BASE_NUM_FILES_TRAIN"
echo "Effective num_files_train: $EFFECTIVE_NUM_FILES_TRAIN"
echo "DLIO generate data: $DLIO_GENERATE_DATA"
echo "DLIO train: $DLIO_TRAIN"
echo "DLIO checkpoint: $DLIO_CHECKPOINT"
echo "DLIO evaluation: $DLIO_EVAL"
echo "DFTracer enabled: $DFTRACER_ENABLE"
if [ "$DFTRACER_ENABLE" -eq 1 ]; then
  # echo "  DFTracer data directory: $DFTRACER_DATA_DIR"
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
echo "Base output directory: $BASE_OUTPUT_DIR"
echo "Dataset root: $DATASET_ROOT"
# echo "Data directory: $DATA_DIR"
echo "Checkpoint directory: $CHECKPOINT_DIR"
echo "DLIO output directory: $DLIO_OUTPUT_DIR"
echo "Traces directory: $DLIO_OUTPUT_DIR"
echo "========================"

env > "$BASE_OUTPUT_DIR/env.txt"
which dlio_benchmark > "$BASE_OUTPUT_DIR/dlio_benchmark_path.txt"
python3 -m pip show dlio_benchmark > "$BASE_OUTPUT_DIR/pip_show_dlio_benchmark.txt" 2>&1 || true

ulimit -c unlimited

# --env=LD_PRELOAD="${DFTRACER_LD_PRELOAD}" \
# --env=DFTRACER_DATA_DIR="${DFTRACER_DATA_DIR}" \
# --env=DFTRACER_INIT="${DFTRACER_INIT}" \
# --env=DFTRACER_LOG_FILE="${DFTRACER_LOG_FILE}" \

if [[ "$DFTRACER_ENABLE" -eq 1 ]]; then
  echo "DFTracer is enabled. Traces will be saved to: $DLIO_OUTPUT_DIR"
  flux run -N "$NUM_NODES" -n "$NUM_PROCS" \
      --exclusive -o fastload=on \
      --env=DFTRACER_ENABLE="${DFTRACER_ENABLE}" \
      --env=DFTRACER_INC_METADATA="${DFTRACER_INC_METADATA}" \
      dlio_benchmark "${DLIO_ARGS[@]}" 2>&1 | tee "$BASE_OUTPUT_DIR/log.txt"
else
  echo "DFTracer is disabled. No traces will be collected."
  flux run -N "$NUM_NODES" -n "$NUM_PROCS" \
      --exclusive -o fastload=on \
      dlio_benchmark "${DLIO_ARGS[@]}" 2>&1 | tee "$BASE_OUTPUT_DIR/log.txt"
fi
