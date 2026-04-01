#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# PREFIX=~/tmp/p/lustre5/$USER/stack/ior
PREFIX=/p/lustre5/$USER/stack/ior
# PREFIX=/usr/WS2/$USER/io-benchmark/ior

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
# 2. IOR (MPI-IO backend)
# ============================================
# Built with -finstrument-functions so DFTracer can trace every function
# entry/exit via __cyg_profile_func_enter/exit hooks.
# -Wl,-E exports all symbols so dladdr can resolve function names.
# -fvisibility=default ensures symbols are not hidden.
# Linked against dftracer_core which provides the instrumentation hooks.
# ============================================
if [ ! -f "$PREFIX/ior-install/bin/ior" ]; then
  echo "==> Building IOR..."
  if [ ! -d ior-src ]; then
    git clone https://github.com/hpc-io/ior.git ior-src
  fi
  cd ior-src
  git checkout master

  # Determine dftracer lib directory (lib or lib64)
  if [ -d "$PREFIX/dftracer/lib64" ]; then
    DFTRACER_LIB_DIR="$PREFIX/dftracer/lib64"
  else
    DFTRACER_LIB_DIR="$PREFIX/dftracer/lib"
  fi

  ./bootstrap
  ./configure \
    --prefix="$PREFIX/ior-install" \
    CC=mpicc \
    CXX=mpicxx \
    CFLAGS="-g -O2 -finstrument-functions -fvisibility=default" \
    CXXFLAGS="-g -O2 -finstrument-functions -fvisibility=default" \
    LDFLAGS="-rdynamic -Wl,-E -Wl,--export-dynamic -L$DFTRACER_LIB_DIR -Wl,-rpath,$DFTRACER_LIB_DIR" \
    LIBS="-ldftracer_core -ldl"
  make -j
  make install INSTALL="install -s --strip-program=/bin/true"
  cd "$PREFIX"
else
  echo "==> IOR already installed, skipping."
fi

echo ""
echo "==> Build complete!"
echo ""
echo "Add to your environment:"
echo "  export PATH=$PREFIX/ior-install/bin:$PREFIX/dftracer/bin:\$PATH"
if [ -d "$PREFIX/dftracer/lib64" ]; then
  echo "  export LD_LIBRARY_PATH=$PREFIX/dftracer/lib:$PREFIX/dftracer/lib64:\$LD_LIBRARY_PATH"
else
  echo "  export LD_LIBRARY_PATH=$PREFIX/dftracer/lib:\$LD_LIBRARY_PATH"
fi
