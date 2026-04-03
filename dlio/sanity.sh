#!/bin/bash
set -euo pipefail

PREFIX=/p/lustre5/$USER/stack/dlio
ROCM_VERSION=${ROCM_VERSION:-7.1.1}
GCC_VERSION=${GCC_VERSION:-12.1}
PY_VERSION=${PY_VERSION:-3.11}

source /etc/profile.d/z00_lmod.sh
module use /opt/toss/modules/modulefiles/

ml load rocm/$ROCM_VERSION
ml load rccl
ml load ninja
ml load gcc-native/$GCC_VERSION
ml load python/$PY_VERSION
ml load cmake/3.29.2

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

TORCH_LIB_DIR="/p/lustre5/$USER/stack/dlio/.venv/lib/python3.11/site-packages/torch/lib"
export LD_LIBRARY_PATH="$ROCM_HOME/lib:$PREFIX/dftracer/lib:$PREFIX/dftracer/lib64:${LD_LIBRARY_PATH:-}"
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

echo "==> Environment"
echo "ROCM_VERSION=$ROCM_VERSION"
echo "ROCM_HOME=$ROCM_HOME"
echo "python=$(which python3)"
echo "mpicc=$(which mpicc)"
echo "torch lib dir=$TORCH_LIB_DIR"
echo ""

echo "==> mpi4py"
python3 - <<'PY'
from mpi4py import MPI
print("mpi4py import: OK")
print("MPI version:", MPI.Get_version())
print("MPI library version:", MPI.Get_library_version())
PY
echo ""

echo "==> torch"
python3 - <<'PY'
import torch
print("torch import: OK")
print("torch version:", torch.__version__)
print("cuda available:", torch.cuda.is_available())
print("hip version:", getattr(torch.version, "hip", None))
PY
echo ""

echo "==> dlio_benchmark"
python3 - <<'PY'
import dlio_benchmark
print("dlio_benchmark import: OK")
print("dlio_benchmark path:", dlio_benchmark.__file__)
PY
echo ""

echo "Sanity checks passed."
