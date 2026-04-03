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

mkdir -p "$PREFIX" && cd "$PREFIX"

# ============================================
# 1. DFTracer (PR #340 - MPI support)
# ============================================
# DFTracer uses ExternalProject to build its dependencies (cpp-logger,
# gotcha, brahma) during the first cmake build. The two-pass approach:
#   Pass 1: cmake + make  -> builds deps into CMAKE_INSTALL_PREFIX
#   Pass 2: cmake + make  -> finds deps, builds dftracer itself
#
# Patch scripts are shared with h5bench (located in $PROJECT_ROOT/h5bench/).
# ============================================
if [ ! -f "$PREFIX/dftracer/lib/libdftracer_preload.so" ] &&
  [ ! -f "$PREFIX/dftracer/lib64/libdftracer_preload.so" ]; then
  echo "==> Building DFTracer (PR #340 with MPI)..."
  if [ ! -d dftracer-src ]; then
    git clone -b feat/support-hdf5-mpi https://github.com/izzet/dftracer.git dftracer-src
  fi
  cd dftracer-src

  # Merge upstream/develop to pick up bug fixes not yet in the HDF5/MPI PR.
  # Uses -X ours to resolve conflicts in favor of the feature branch,
  # preserving the MPI additions. Idempotent: skips if already merged.
  if ! git remote | grep -q '^upstream$'; then
    git remote add upstream https://github.com/llnl/dftracer.git
  fi
  git fetch upstream develop
  if ! git merge-base --is-ancestor upstream/develop HEAD 2>/dev/null; then
    git merge upstream/develop -X ours --no-edit
  fi

  DFTRACER_COMMON_ARGS=(
    -DCMAKE_INSTALL_PREFIX="$PREFIX/dftracer"
    -DCMAKE_C_COMPILER=mpicc
    -DCMAKE_CXX_COMPILER=mpicxx
    -DMPI_C_COMPILER=mpicc
    -DMPI_CXX_COMPILER=mpicxx
    -DDFTRACER_ENABLE_MPI=ON
    -DCMAKE_CXX_FLAGS="-fpermissive"
    -DCMAKE_PREFIX_PATH="$PREFIX/dftracer"
    -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
  )

  # Pass 1: build external dependencies (cpp-logger, gotcha, brahma)
  # ExternalProject installs deps into CMAKE_INSTALL_PREFIX during build
  echo "  -> Pass 1: Building dependencies..."
  rm -rf build && mkdir build && cd build
  cmake .. "${DFTRACER_COMMON_ARGS[@]}" -DDFTRACER_INSTALL_DEPENDENCIES=ON
  make -j || true # first pass may partially fail after deps are built
  cd "$PREFIX/dftracer-src"

  # ---- Fix brahma: force Cray MPICH detection ----
  # Brahma's CMake fails to detect Cray MPICH as a known MPI implementation,
  # so BRAHMA_MPI_IMPL_CRAYMPICH is never defined in brahma_config.hpp.
  # Without it, every MPI-IO wrapper function in mpiio.cpp is #ifdef'd out.
  BRAHMA_CONFIG="$PREFIX/dftracer/include/brahma/brahma_config.hpp"
  if [ -f "$BRAHMA_CONFIG" ] && ! grep -q 'BRAHMA_MPI_IMPL_CRAYMPICH' "$BRAHMA_CONFIG"; then
    echo "  -> Patching brahma_config.hpp: adding BRAHMA_MPI_IMPL_CRAYMPICH..."
    sed -i '/BRAHMA_ENABLE_MPI/a #define BRAHMA_MPI_IMPL_CRAYMPICH' "$BRAHMA_CONFIG"
  fi

  # ---- Fix pre-existing dftracer bug: std::string in variadic macro ----
  # configuration_manager.cpp passes std::string to %d format specifier
  CFGMGR="src/dftracer/core/utils/configuration_manager.cpp"
  if grep -q 'aggregation_enable %d.*aggregation_file)' "$CFGMGR" 2>/dev/null; then
    echo "  -> Fixing configuration_manager.cpp varargs bug..."
    sed -i 's/aggregation_enable %d",\s*this->aggregation_file)/aggregation_file %s", this->aggregation_file.c_str())/' "$CFGMGR"
  fi

  # ---- Apply local DFTracer finstrument crash fix (if provided) ----
  # Copies user-maintained patch source into dftracer before build.
  # Optional and idempotent.
  USER_FTRACE_PATCH_H="$PROJECT_ROOT/h5bench/patches/dftracer/functions.h"
  DFTRACER_FTRACE_H="$PREFIX/dftracer-src/src/dftracer/core/finstrument/functions.h"
  if [ -f "$USER_FTRACE_PATCH_H" ]; then
    if ! cmp -s "$USER_FTRACE_PATCH_H" "$DFTRACER_FTRACE_H"; then
      echo "  -> Applying local patch: patches/dftracer/functions.h"
      cp "$USER_FTRACE_PATCH_H" "$DFTRACER_FTRACE_H"
    else
      echo "  -> Local patch already applied: patches/dftracer/functions.h"
    fi
  else
    echo "  -> Local patch not found, skipping: $USER_FTRACE_PATCH_H"
  fi

  USER_FTRACE_PATCH_CPP="$PROJECT_ROOT/h5bench/patches/dftracer/functions.cpp"
  DFTRACER_FTRACE_CPP="$PREFIX/dftracer-src/src/dftracer/core/finstrument/functions.cpp"
  if [ -f "$USER_FTRACE_PATCH_CPP" ]; then
    if ! cmp -s "$USER_FTRACE_PATCH_CPP" "$DFTRACER_FTRACE_CPP"; then
      echo "  -> Applying local patch: patches/dftracer/functions.cpp"
      cp "$USER_FTRACE_PATCH_CPP" "$DFTRACER_FTRACE_CPP"
    else
      echo "  -> Local patch already applied: patches/dftracer/functions.cpp"
    fi
  else
    echo "  -> Local patch not found, skipping: $USER_FTRACE_PATCH_CPP"
  fi

  # ---- Force MPI detection on Cray systems ----
  # Cray provides MPI through compiler wrappers (mpicc/mpicxx) which handle
  # include paths and linking automatically. However, CMake's find_package(MPI)
  # fails to detect this, so DFTRACER_MPI_ENABLE never gets set and MPI-IO
  # wrappers are skipped. We patch CMakeLists.txt to force-enable MPI when
  # DFTRACER_ENABLE_MPI is ON, since we know mpicc is the compiler.
  if grep -q 'MPI_CXX_FOUND' CMakeLists.txt; then
    echo "  -> Patching CMakeLists.txt: force MPI detection for Cray..."
    sed -i 's/if(MPI_CXX_FOUND AND (\(DFTRACER_ENABLE_MPI\)/if((\1)/' CMakeLists.txt
  fi

  # Pass 2: deps now in $PREFIX/dftracer, find_package can locate them
  echo "  -> Pass 2: Building DFTracer..."
  rm -rf build && mkdir build && cd build
  cmake .. "${DFTRACER_COMMON_ARGS[@]}" -DDFTRACER_ENABLE_FTRACING=ON
  make -j
  make install
  cd "$PREFIX"
else
  echo "==> DFTracer already installed, skipping."
fi

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

echo "==> Installing DLIO Benchmark in editable mode..."
python3 -m pip install --upgrade pip
python3 -m pip install --force-reinstall "mpi4py==4.1.0.dev0+mpich.8.1.32"
python3 -m pip uninstall -y torch torchvision torchaudio || true
python3 -m pip install --no-cache-dir --force-reinstall torch torchvision torchaudio
python3 -m pip install aistore
python3 -m pip install -e "$DLIO_SRC_DIR"

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
