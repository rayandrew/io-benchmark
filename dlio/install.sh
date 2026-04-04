#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFIX=/p/lustre5/$USER/stack/dlio

ml load gcc-native/12.1
ml load cmake/3.29.2
ml load python/3.11

if [ ! -f "$PREFIX/.venv/bin/activate" ]; then
  echo "==> Creating new virtual environment..."
  python3 -m venv "$PREFIX/.venv"
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

mkdir -p "$PREFIX" && cd "$PREFIX"

# ============================================
# 2. DLIO Benchmark (editable Python install)
# ============================================
DLIO_REPO_URL="${DLIO_REPO_URL:-https://github.com/argonne-lcf/dlio_benchmark.git}"
DLIO_SRC_DIR="${DLIO_SRC_DIR:-$PREFIX/dlio_benchmark-src}"

if [ ! -d "$DLIO_SRC_DIR/.git" ]; then
  echo "==> Cloning DLIO Benchmark..."
  git clone "$DLIO_REPO_URL" "$DLIO_SRC_DIR"
else
  echo "==> DLIO Benchmark source already present, skipping clone."
fi

USER_DLIO_PATCH_MAIN="$PROJECT_ROOT/dlio/patches/dlio_benchmark/main.py"
DLIO_MAIN="$DLIO_SRC_DIR/dlio_benchmark/main.py"
if [ -f "$USER_DLIO_PATCH_MAIN" ]; then
  if ! cmp -s "$USER_DLIO_PATCH_MAIN" "$DLIO_MAIN"; then
    echo "==> Applying local patch: dlio/patches/dlio_benchmark/main.py"
    cp "$USER_DLIO_PATCH_MAIN" "$DLIO_MAIN"
  else
    echo "==> Local DLIO main.py patch already applied."
  fi
else
  echo "==> Local DLIO main.py patch not found, skipping: $USER_DLIO_PATCH_MAIN"
fi

echo "==> Installing DLIO Benchmark in editable mode..."
python3 -m pip install --upgrade pip
python3 -m pip install --force-reinstall "mpi4py==4.1.0.dev0+mpich.8.1.32"
python3 -m pip uninstall -y torch torchvision torchaudio || true
python3 -m pip install --no-cache-dir --force-reinstall torch torchvision torchaudio
python3 -m pip install \
  "Pillow>=9.3.0" \
  "PyYAML>=6.0.0" \
  "h5py>=3.11.0" \
  "hydra-core==1.3.2" \
  "numpy>=1.23.5" \
  "omegaconf>=2.2.0" \
  "pandas>=1.5.1" \
  "psutil>=5.9.8" \
  "pydftracer>=2.0.2" \
  aistore
python3 -m pip install --no-deps -e "$DLIO_SRC_DIR"
python3 -m pip install git+https://github.com/LLNL/dftracer.git@develop

echo ""
echo "==> Build complete!"
echo ""
echo "Add to your environment:"
echo "  export PATH=$PREFIX/dftracer/bin:\$PATH"
echo "  export PYTHONPATH=$PREFIX/dlio_benchmark-src:\$PYTHONPATH"
echo "  export LD_LIBRARY_PATH=$PREFIX/.venv/lib/python3.11/site-packages/torch/lib:\$LD_LIBRARY_PATH"
if [ -d "$PREFIX/dftracer/lib64" ]; then
  echo "  export LD_LIBRARY_PATH=$PREFIX/dftracer/lib:$PREFIX/dftracer/lib64:\$LD_LIBRARY_PATH"
else
  echo "  export LD_LIBRARY_PATH=$PREFIX/dftracer/lib:\$LD_LIBRARY_PATH"
fi
