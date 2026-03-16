#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX=/p/lustre5/$USER/stack/h5bench
# PREFIX=/usr/WS2/$USER/io-benchmark/h5bench


ml load gcc-native/12.1
ml load cmake/3.29.2
ml load python/3.11

echo "==> Activating existing virtual environment..."
source "$PREFIX/.venv/bin/activate"

# pip install libclang

mkdir -p "$PREFIX" && cd "$PREFIX"

# ============================================
# 1. HDF5
# ============================================
if [ ! -f "$PREFIX/hdf5/lib/libhdf5.so" ]; then
  echo "==> Building HDF5..."
  if [ ! -d hdf5-src ]; then
    git clone https://github.com/HDFGroup/hdf5.git hdf5-src
  fi
  cd hdf5-src
  # git checkout hdf5_2.1.0
  git checkout hdf5_1.14.5
  # git checkout hdf5_1_8_23
  rm -rf build && mkdir build && cd build
  cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX/hdf5" \
    -DHDF5_ENABLE_PARALLEL=ON \
    -DHDF5_ENABLE_THREADSAFE=ON \
    -DALLOW_UNSUPPORTED=ON \
    -DCMAKE_C_COMPILER=mpicc \
    -DCMAKE_C_FLAGS="-pthread" \
    -DCMAKE_EXE_LINKER_FLAGS="-lpthread"

    # -DHDF5_ALLOW_UNSUPPORTED=ON \ for v2
  make -j
  make install
  cd "$PREFIX"
else
  echo "==> HDF5 already installed, skipping."
fi

# ============================================
# 2. Argobots
# ============================================
if [ ! -f "$PREFIX/argobots/lib/libabt.so" ]; then
  echo "==> Building Argobots..."
  if [ ! -d argobots-src ]; then
    git clone https://github.com/pmodels/argobots.git argobots-src
  fi
  cd argobots-src
  ./autogen.sh
  ./configure --prefix="$PREFIX/argobots" CC=mpicc
  make -j
  make install
  cd "$PREFIX"
else
  echo "==> Argobots already installed, skipping."
fi

# ============================================
# 3. vol-async
# ============================================
if [ ! -f "$PREFIX/vol-async/lib/libh5async.so" ]; then
  echo "==> Building vol-async..."
  if [ ! -d vol-async-src ]; then
    git clone https://github.com/hpc-io/vol-async.git vol-async-src
  fi
  cd vol-async-src
  # git checkout v1.3
  export HDF5_DIR="$PREFIX/hdf5"
  rm -rf build && mkdir build && cd build
  cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX/vol-async" \
    -DCMAKE_PREFIX_PATH="$PREFIX/hdf5;$PREFIX/argobots" \
    -DCMAKE_C_COMPILER=mpicc
  make -j
  make install
  cd "$PREFIX"
else
  echo "==> vol-async already installed, skipping."
fi

# ============================================
# 4. DFTracer (PR #340 - HDF5/MPI support)
# ============================================
# DFTracer uses ExternalProject to build its dependencies (cpp-logger,
# gotcha, brahma) during the first cmake build. The two-pass approach:
#   Pass 1: cmake + make  -> builds deps into CMAKE_INSTALL_PREFIX
#   Pass 2: cmake + make  -> finds deps, builds dftracer itself
#
# Two patches are applied between passes:
#   a) brahma header: #undef HDF5 async API macros (HDF5 >= 1.13.0)
#   b) dftracer generated wrappers: fix type mismatches from libclang
#      resolving typedef/enum/struct types to 'int'
# ============================================
if [ ! -f "$PREFIX/dftracer/lib/libdftracer_preload.so" ] && \
   [ ! -f "$PREFIX/dftracer/lib64/libdftracer_preload.so" ]; then
  echo "==> Building DFTracer (PR #340 with HDF5/MPI)..."
  if [ ! -d dftracer-src ]; then
    git clone -b feat/support-hdf5-mpi https://github.com/izzet/dftracer.git dftracer-src
  fi
  cd dftracer-src

  # Merge upstream/develop to pick up bug fixes not yet in the HDF5/MPI PR.
  # Uses -X ours to resolve conflicts in favor of the feature branch,
  # preserving the HDF5/MPI additions. Idempotent: skips if already merged.
  if ! git remote | grep -q '^upstream$'; then
    git remote add upstream https://github.com/llnl/dftracer.git
  fi
  git fetch upstream develop
  if ! git merge-base --is-ancestor upstream/develop HEAD 2>/dev/null; then
    git merge upstream/develop -X ours --no-edit
  fi

  # Set HDF5 so cmake's find_package can locate it
  export HDF5_DIR="$PREFIX/hdf5"
  export HDF5_ROOT="$PREFIX/hdf5"
  export CMAKE_PREFIX_PATH="$PREFIX/hdf5:$CMAKE_PREFIX_PATH"

  DFTRACER_COMMON_ARGS=(
    -DCMAKE_INSTALL_PREFIX="$PREFIX/dftracer"
    -DCMAKE_C_COMPILER=mpicc
    -DCMAKE_CXX_COMPILER=mpicxx
    -DDFTRACER_ENABLE_MPI=ON
    -DDFTRACER_ENABLE_HDF5=ON
    -DCMAKE_CXX_FLAGS="-fpermissive"
    -DCMAKE_PREFIX_PATH="$PREFIX/dftracer;$PREFIX/hdf5"
    -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
  )

  # Pass 1: build external dependencies (cpp-logger, gotcha, brahma)
  # ExternalProject installs deps into CMAKE_INSTALL_PREFIX during build
  echo "  -> Pass 1: Building dependencies..."
  rm -rf build && mkdir build && cd build
  cmake .. "${DFTRACER_COMMON_ARGS[@]}" -DDFTRACER_INSTALL_DEPENDENCIES=ON
  make -j || true  # first pass may partially fail after deps are built
  cd "$PREFIX/dftracer-src"

  # ---- Patch brahma: undef HDF5 async macros (HDF5 >= 1.13.0) ----
  # HDF5 1.14.x defines function-like macros (e.g. H5Fopen_async(...))
  # that inject __FILE__/__func__/__LINE__, corrupting brahma's virtual
  # method declarations. We undef them after #include <hdf5.h>.
  # Idempotent: checks if patch was already applied.
  BRAHMA_HDF5_H="$PREFIX/dftracer/include/brahma/interface/hdf5.h"
  if [ -f "$BRAHMA_HDF5_H" ] && ! grep -q 'undef H5Fopen_async' "$BRAHMA_HDF5_H"; then
    echo "  -> Patching brahma: undef HDF5 async API macros..."
    sed -i '/#include <hdf5.h>/a \
\
/* Undef HDF5 >= 1.13 async API macros that conflict with brahma methods */\
#if (BRAHMA_HDF5_VERSION >= 101300)\
#undef H5Acreate_async\
#undef H5Acreate_by_name_async\
#undef H5Aopen_async\
#undef H5Aopen_by_name_async\
#undef H5Aopen_by_idx_async\
#undef H5Awrite_async\
#undef H5Aread_async\
#undef H5Arename_async\
#undef H5Arename_by_name_async\
#undef H5Aexists_async\
#undef H5Aexists_by_name_async\
#undef H5Aclose_async\
#undef H5Dcreate_async\
#undef H5Dopen_async\
#undef H5Dget_space_async\
#undef H5Dread_async\
#undef H5Dread_multi_async\
#undef H5Dwrite_async\
#undef H5Dwrite_multi_async\
#undef H5Dset_extent_async\
#undef H5Dclose_async\
#undef H5Fcreate_async\
#undef H5Fopen_async\
#undef H5Freopen_async\
#undef H5Fflush_async\
#undef H5Fclose_async\
#undef H5Gcreate_async\
#undef H5Gopen_async\
#undef H5Gget_info_async\
#undef H5Gget_info_by_name_async\
#undef H5Gget_info_by_idx_async\
#undef H5Gclose_async\
#undef H5Lcreate_hard_async\
#undef H5Lcreate_soft_async\
#undef H5Ldelete_async\
#undef H5Ldelete_by_idx_async\
#undef H5Lexists_async\
#undef H5Literate_async\
#undef H5Mcreate_async\
#undef H5Mopen_async\
#undef H5Mclose_async\
#undef H5Mput_async\
#undef H5Mget_async\
#undef H5Oopen_async\
#undef H5Oopen_by_idx_async\
#undef H5Oget_info_by_name_async\
#undef H5Oclose_async\
#undef H5Oflush_async\
#undef H5Orefresh_async\
#undef H5Ocopy_async\
#undef H5Ropen_object_async\
#undef H5Ropen_region_async\
#undef H5Ropen_attr_async\
#undef H5Tcommit_async\
#undef H5Topen_async\
#undef H5Tclose_async\
#endif' "$BRAHMA_HDF5_H"
  fi

  # ---- Patch dftracer: fix type mismatches in generated wrappers ----
  # libclang resolves typedef/enum/struct types to 'int', causing override
  # signature mismatches with brahma base class. The Python script compares
  # brahma's correct virtual method signatures with dftracer's generated
  # overrides and fixes all mismatches automatically.
  # Also fixes _Bool -> bool (C99-only keyword, not valid in C++).
  # Idempotent: script detects if signatures already match.
  echo "  -> Patching dftracer: fixing type mismatches in generated HDF5 wrappers..."
  python3 "$SCRIPT_DIR/fix_dftracer_types.py" \
    "$BRAHMA_HDF5_H" \
    src/dftracer/core/brahma/hdf5.h \
    src/dftracer/core/brahma/hdf5.cpp

  # ---- Patch brahma/dftracer: fix async GOTCHA wrapper ABI mismatch ----
  # HDF5 >= 1.13 async symbols have 3 extra params (app_file, app_func,
  # app_line) that brahma's GOTCHA wrappers don't include (they use the
  # H5_DOXYGEN simplified declarations). This causes argument corruption
  # when GOTCHA intercepts real async calls at the PLT level.
  # Idempotent: script checks if already patched.
  echo "  -> Patching brahma/dftracer: fixing async GOTCHA wrapper signatures..."
  BRAHMA_INTERCEPTOR_H="$PREFIX/dftracer/include/brahma/interceptor.h"
  python3 "$SCRIPT_DIR/fix_async_wrappers.py" \
    "$BRAHMA_INTERCEPTOR_H" \
    "$BRAHMA_HDF5_H" \
    src/dftracer/core/brahma/hdf5.cpp

  # ---- Fix pre-existing dftracer bug: std::string in variadic macro ----
  # configuration_manager.cpp passes std::string to %d format specifier
  CFGMGR="src/dftracer/core/utils/configuration_manager.cpp"
  if grep -q 'aggregation_enable %d.*aggregation_file)' "$CFGMGR" 2>/dev/null; then
    echo "  -> Fixing configuration_manager.cpp varargs bug..."
    sed -i 's/aggregation_enable %d",\s*this->aggregation_file)/aggregation_file %s", this->aggregation_file.c_str())/' "$CFGMGR"
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
# 5. h5bench
# ============================================
if [ ! -f "$PREFIX/h5bench-install/bin/h5bench_write" ]; then
  echo "==> Building h5bench..."
  if [ ! -d h5bench-src ]; then
    git clone https://github.com/hpc-io/h5bench.git h5bench-src
    cd h5bench-src && git checkout 1.6 && cd "$PREFIX"
  fi

  # Replace h5bench_write.c with the DFTracer-annotated version.
  # Idempotent: checks for DFTRACER_C_FUNCTION_START marker.
  # H5BENCH_WRITE="$PREFIX/h5bench-src/h5bench_patterns/h5bench_write.c"
  # if ! grep -q 'DFTRACER_C_FUNCTION_START' "$H5BENCH_WRITE" 2>/dev/null; then
  #   echo "  -> Replacing h5bench_write.c with DFTracer-annotated version..."
  #   cp "$SCRIPT_DIR/h5bench_write.c" "$H5BENCH_WRITE"
  # fi

  # Patch h5bench CMakeLists.txt: add optional DFTracer function instrumentation.
  # When WITH_DFTRACER=ON, cmake applies DFTRACER_FUNCTION_FLAGS (-g
  # -finstrument-functions -Wl,-E -fvisibility=default) and links dftracer_core
  # to all targets so every h5bench function entry/exit is traced.
  # Idempotent: guarded by grep check.
  H5BENCH_CMAKE="$PREFIX/h5bench-src/CMakeLists.txt"
  if ! grep -q 'WITH_DFTRACER' "$H5BENCH_CMAKE"; then
    echo "  -> Patching h5bench CMakeLists.txt: adding DFTracer instrumentation option..."
    sed -i '/^find_package(MPI REQUIRED)/a \
\
# Optional DFTracer function-level instrumentation (-finstrument-functions)\
option(WITH_DFTRACER "Enable DFTracer function-level instrumentation" OFF)\
if(WITH_DFTRACER)\
    find_package(dftracer REQUIRED)\
    message(STATUS "DFTracer: function instrumentation enabled (${DFTRACER_FUNCTION_FLAGS})")\
    add_compile_options(${DFTRACER_FUNCTION_FLAGS})\
    link_libraries(dftracer::dftracer_core)\
endif()' "$H5BENCH_CMAKE"
  fi

  cd $PREFIX/h5bench-src
  rm -rf build && mkdir build && cd build
  cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX/h5bench-install" \
    -DCMAKE_C_COMPILER=mpicc \
    -DCMAKE_CXX_COMPILER=mpicxx \
    -DWITH_ASYNC_VOL=ON \
    -DWITH_DFTRACER=ON \
    -Ddftracer_DIR="$PREFIX/dftracer/lib64/cmake/dftracer" \
    -DCMAKE_PREFIX_PATH="$PREFIX/hdf5;$PREFIX/vol-async;$PREFIX/argobots;$PREFIX/dftracer" \
    -DCMAKE_C_FLAGS="-I$PREFIX/vol-async/include -I$PREFIX/hdf5/include" \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,-E -L$PREFIX/hdf5/lib -lhdf5 -L$PREFIX/vol-async/lib -lh5async -L$PREFIX/argobots/lib -labt"
  make -j
  make install
  cd "$PREFIX"
else
  echo "==> h5bench already installed, skipping."
fi
echo ""
echo "==> Build complete!"
echo ""
echo "Add to your environment:"
echo "  export PATH=$PREFIX/h5bench-install/bin:$PREFIX/hdf5/bin:$PREFIX/dftracer/bin:\$PATH"
echo "  export LD_LIBRARY_PATH=$PREFIX/vol-async/lib:$PREFIX/hdf5/lib:$PREFIX/argobots/lib:$PREFIX/dftracer/lib:$PREFIX/dftracer/lib64:\$LD_LIBRARY_PATH"
echo "  export HDF5_DIR=$PREFIX/hdf5"
echo "  export HDF5_PLUGIN_PATH=$PREFIX/vol-async/lib"
echo "  export HDF5_VOL_CONNECTOR=\"async under_vol=0;under_info={}\""
