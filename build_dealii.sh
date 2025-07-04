#!/bin/bash

set -e

# === Check for required tools ===
declare -A packages=(
    ["cmake"]="cmake"
    ["ccache"]="ccache"
    ["git"]="git"
    ["make"]="build-essential"
)

for cmd in "${!packages[@]}"; do
    package_name="${packages[$cmd]}"

    echo "==== CHECK FOR $cmd ===="
    if ! command -v "$cmd" &> /dev/null; then
        echo "❌ Error: $cmd is not installed or not in your PATH."
        echo "Attempting to install $package_name..."
        sudo apt-get update
        sudo apt-get install -y "$package_name"
        if ! command -v "$cmd" &> /dev/null; then
            echo "❌ Error: Failed to install $cmd. Please install it manually."
            exit 1
        else
            echo "✅ $cmd successfully installed."
        fi
    else
        echo "✅ $cmd found: $("$cmd" --version | head -n 1)"
    fi
done

echo "All required tools checked."

# === Config ===
INSTALL_DIR="$(pwd)/install"
NATIVE_BUILD_DIR="native_build"
WASM_BUILD_DIR="dealii_wasm_build"
EXAMPLE_NAME="minimal_dealii"
THREADS=$(nproc)

# === Setup Emscripten ===
if [ ! -d "emsdk" ]; then
  git clone https://github.com/emscripten-core/emsdk.git
  cd emsdk
  ./emsdk install latest
  ./emsdk activate latest
  cd ..
fi
source ./emsdk/emsdk_env.sh

# === Build upstream Kokkos ===
KOKKOS_REPO="https://github.com/kokkos/kokkos.git"
KOKKOS_COMMIT="3e7dfc68cc1fb371c345ef42cb0f0d97caee8b81"  # example commit
KOKKOS_DIR="external/kokkos"
KOKKOS_INSTALL_DIR="$INSTALL_DIR/kokkos"

if [ ! -d "$KOKKOS_DIR" ]; then
  echo "📦 Cloning Kokkos at commit $KOKKOS_COMMIT..."
  mkdir -p "$(dirname "$KOKKOS_DIR")"
  git init "$KOKKOS_DIR"
  cd "$KOKKOS_DIR"
  git remote add origin "$KOKKOS_REPO"
  git fetch --depth=1 origin "$KOKKOS_COMMIT"
  git checkout "$KOKKOS_COMMIT"
  cd -
else
  echo "✅ Kokkos already exists at $KOKKOS_DIR"
fi

mkdir -p "$KOKKOS_DIR/build"
cd "$KOKKOS_DIR/build"

emcmake cmake .. \
  -DCMAKE_INSTALL_PREFIX="$KOKKOS_INSTALL_DIR" \
  -DCMAKE_CXX_STANDARD=17 \
  -DKokkos_ENABLE_SERIAL=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DKOKKOS_IMPL_32BIT=ON \
  -DKokkos_ENABLE_DEPRECATED_CODE=OFF \
  -DCMAKE_CXX_FLAGS="-DKOKKOS_IMPL_32BIT -pthread -matomics -mbulk-memory"

make -j${THREADS}
make install
cd -

if [ ! -f "$INSTALL_DIR/kokkos/lib/cmake/Kokkos/KokkosConfig.cmake" ]; then
  echo "❌ KokkosConfig.cmake not found. Kokkos install may have failed."
  exit 1
fi

# === OpenCASCADE config ===
OCC_REPO="https://git.dev.opencascade.org/repos/occt.git"
OCC_COMMIT="22d437b771eb322dcceec3ad0efec6876721b8a9"
OCC_DIR="external/opencascade"
OCC_BUILD_DIR="$OCC_DIR/build"
OCC_INSTALL_DIR="$INSTALL_DIR/opencascade"

# === Clone OpenCASCADE if needed ===
if [ ! -d "$OCC_DIR" ]; then
  echo "📦 Cloning OpenCASCADE at commit $OPENCASCADE_COMMIT..."

  mkdir -p "$(dirname "$OCC_DIR")"
  git init "$OCC_DIR"
  cd "$OCC_DIR"
  git remote add origin "$OCC_REPO"
  git fetch --depth=1 origin "$OCC_COMMIT"
  git checkout "$OCC_COMMIT"
  cd -
else
  echo "✅ OpenCASCADE already exists at $OCC_DIR"
fi

OCC_LIB_DIR="$OCC_INSTALL_DIR/lib"

# === Build OpenCASCADE with Emscripten ===
mkdir -p "$OCC_BUILD_DIR"
cd "$OCC_BUILD_DIR"

echo "⚙️  Configuring OpenCASCADE with Emscripten..."
cmake .. \
  -DCMAKE_TOOLCHAIN_FILE="$(pwd)/../../../emsdk/upstream/emscripten/cmake/Modules/Platform/Emscripten.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$OCC_INSTALL_DIR" \
  -DBUILD_MODULE_ApplicationFramework=OFF \
  -DBUILD_MODULE_Draw=OFF \
  -DBUILD_MODULE_Visualization=OFF \
  -DBUILD_MODULE_Inspection=OFF \
  -DBUILD_MODULE_Modeling=ON \
  -DBUILD_MODULE_Exchange=ON \
  -DBUILD_MODULE_DataExchange=ON \
  -DBUILD_MODULE_ModelingData=ON \
  -DBUILD_MODULE_ModelingAlgorithms=ON \
  -DBUILD_MODULE_XCAF=ON \
  -DBUILD_LIBRARY_TYPE=Static \
  -DUSE_FREEIMAGE=OFF \
  -DUSE_FREETYPE=OFF \
  -DUSE_TBB=OFF \
  -DUSE_GL2PS=OFF \
  -DUSE_OPENGL=OFF \
  -DUSE_XLIB=OFF \
  -DCXX_COMPILER_LAUNCHER="ccache"

echo "🔨 Building OpenCASCADE..."
emmake make -j$(nproc)
emmake make install

cd -

# === Clone deal.II ===
DEAL_II_COMMIT="0674a6cf7bf160eb634e37908173b59bb85af789"
DEAL_II_DIR="dealii"
DEAL_II_REPO="https://github.com/dealii/dealii.git"

if [ ! -d "$DEAL_II_DIR" ]; then
  echo "📥 Cloning deal.II at commit $DEAL_II_COMMIT..."
  git init "$DEAL_II_DIR"
  cd "$DEAL_II_DIR"
  git remote add origin "$DEAL_II_REPO"
  git fetch --depth=1 origin "$DEAL_II_COMMIT"
  git checkout "$DEAL_II_COMMIT"
  cd -
else
  echo "✅ deal.II already exists at $DEAL_II_DIR"
fi

# === Native build to generate expand_instantiations tool ===
if [ ! -f "${NATIVE_BUILD_DIR}/bin/expand_instantiations" ]; then
  mkdir -p "$NATIVE_BUILD_DIR"
  cd "$NATIVE_BUILD_DIR"
  cmake "../$DEAL_II_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DDEAL_II_COMPONENT_EXAMPLES=OFF \
    -DDEAL_II_BUILD_EXPAND_INSTANTIATIONS=ON
  make -j${THREADS} expand_instantiations_exe
  echo "✅ expand_instantiations_exe built and available at ${NATIVE_BUILD_DIR}/bin/expand_instantiations"
  cd ..
fi


# === Ensure expand_instantiations is usable ===
if [ ! -x "${NATIVE_BUILD_DIR}/bin/expand_instantiations" ]; then
  echo "❌ expand_instantiations is not executable or missing!"
  exit 1
fi
echo "✅ Native expand_instantiations found: ${NATIVE_BUILD_DIR}/bin/expand_instantiations"
file "${NATIVE_BUILD_DIR}/bin/expand_instantiations"

mkdir -p "$WASM_BUILD_DIR"
cd "$WASM_BUILD_DIR"

echo "🔍 Using native expand_instantiations: ${NATIVE_BUILD_DIR}/bin/expand_instantiations"
file "${NATIVE_BUILD_DIR}/bin/expand_instantiations"

OPENCASCADE_LIBRARIES=$(find "$OCC_INSTALL_DIR/lib" -name 'libTK*.a' -o -name 'libTKernel.a' | sort | tr '\n' ';')


# === Configure deal.II for Emscripten with upstream Kokkos ===
emcmake cmake "../$DEAL_II_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_SKIP_INSTALL_RULES=ON \
  -DDEAL_II_COMPONENT_EXAMPLES=OFF \
  -DDEAL_II_WITH_OPENCASCADE=ON \
  -DOPENCASCADE_INCLUDE_DIR="$OCC_INSTALL_DIR/include/opencascade" \
  -DOPENCASCADE_INCLUDE_DIRS="$OCC_INSTALL_DIR/include/opencascade;$OCC_INSTALL_DIR/include" \
  -DOPENCASCADE_LIBRARIES="$OPENCASCADE_LIBRARIES" \
  -DDEAL_II_WITH_BOOST=ON \
  -DDEAL_II_FORCE_BUNDLED_BOOST=ON \
  -DDEAL_II_WITH_MPI=OFF \
  -DDEAL_II_WITH_P4EST=OFF \
  -DDEAL_II_WITH_64BIT_INDICES=OFF \
  -DDEAL_II_WITH_LAPACK=OFF \
  -DDEAL_II_WITH_HDF5=OFF \
  -DDEAL_II_WITH_TRILINOS=OFF \
  -DDEAL_II_WITH_SUNDIALS=OFF \
  -DDEAL_II_WITH_MUMPS=OFF \
  -DDEAL_II_WITH_SYMENGINE=OFF \
  -DDEAL_II_WITH_GSL=OFF \
  -DDEAL_II_WITH_VTK=OFF \
  -DDEAL_II_WITH_ARBORX=OFF \
  -DDEAL_II_WITH_TBB=OFF \
  -DDEAL_II_WITH_KOKKOS=ON \
  -DKOKKOS_DIR="$KOKKOS_INSTALL_DIR/lib/cmake/Kokkos" \
  -DDEAL_II_FORCE_BUNDLED_TASKFLOW=ON \
  -DDEAL_II_TASKFLOW_BACKEND=Pool \
  -DCMAKE_CXX_FLAGS="-pthread -sUSE_PTHREADS=1 -DKOKKOS_IMPL_32BIT" \
  -DDEAL_II_BUILD_EXPAND_INSTANTIATIONS=OFF \
  -DDEAL_II_USE_PRECOMPILED_INSTANCES=ON \
  -DEXPAND_INSTANTIATIONS_EXE="$PWD/../$NATIVE_BUILD_DIR/bin/expand_instantiations" \
  -DCXX_COMPILER_LAUNCHER="ccache" \

export PATH="$PWD/../$NATIVE_BUILD_DIR/bin:$PATH"
# === Build deal.II ===
emmake make -j${THREADS}

BOOST_VERSION="1.84.0"
BOOST_DIR="external/boost"
BOOST_TARBALL="boost_1_84_0.tar.gz"
BOOST_URL="https://archives.boost.io/release/${BOOST_VERSION}/source/${BOOST_TARBALL}"

if [ ! -d "$BOOST_DIR" ]; then
  echo "📦 Downloading Boost ${BOOST_VERSION}..."
  mkdir -p external
  wget -q --show-progress "$BOOST_URL" -O "external/${BOOST_TARBALL}" || curl -L "$BOOST_URL" -o "external/${BOOST_TARBALL}"

  echo "📦 Extracting Boost..."
  tar -xf "external/${BOOST_TARBALL}" -C external
  mv "external/boost_1_84_0" "$BOOST_DIR"

  echo "📦 Bootstrapping Boost headers..."
  cd "$BOOST_DIR"
  ./bootstrap.sh
  ./b2 headers
  cd -
else
  echo "✅ Boost already exists at $BOOST_DIR"
fi

TASKFLOW_REPO="https://github.com/taskflow/taskflow.git"
TASKFLOW_COMMIT="83591c4a5f55eb4f0d5760a508da34b7a11f71ee"
TASKFLOW_DIR="external/taskflow"

if [ ! -d "$TASKFLOW_DIR" ]; then
  echo "📦 Cloning Taskflow at commit $TASKFLOW_COMMIT..."
  mkdir -p "$(dirname "$TASKFLOW_DIR")"
  git init "$TASKFLOW_DIR"
  cd "$TASKFLOW_DIR"
  git remote add origin "$TASKFLOW_REPO"
  git fetch --depth=1 origin "$TASKFLOW_COMMIT"
  git checkout "$TASKFLOW_COMMIT"
  cd -
else
  echo "✅ Taskflow already exists at $TASKFLOW_DIR"
fi

# === Write a minimal example ===
cat > "${EXAMPLE_NAME}.cc" <<EOF
#include <deal.II/grid/tria.h>
#include <deal.II/grid/grid_generator.h>
#include <deal.II/base/logstream.h>
#include <iostream>

int main()
{
  // dealii::MultithreadInfo::set_thread_limit(1); // Disable multithreading!

  dealii::Triangulation<2> tria;
  dealii::GridGenerator::hyper_cube(tria);
  tria.refine_global(2);

  std::cout << "Active cells: " << tria.n_active_cells() << "\n";
  return 0;
}
EOF

# === Compile example to WebAssembly ===
em++ -O1 "${EXAMPLE_NAME}.cc" ./lib/libdeal_II.a \
  "$INSTALL_DIR/kokkos/lib/libkokkoscontainers.a" \
  "$INSTALL_DIR/kokkos/lib/libkokkoscore.a" \
  -sASSERTIONS=2 -sEXIT_RUNTIME=1 -sENVIRONMENT=web \
  -I../dealii/include \
  -I../dealii/bundled/taskflow-3.10.0 \
  -I./include \
  -I"$INSTALL_DIR/kokkos/include" \
  -I"$BOOST_DIR" \
  -I"$TASKFLOW_DIR" \
  -std=c++17 \
  -sINITIAL_MEMORY=2048MB \
  -sEXIT_RUNTIME=1 \
  -sENVIRONMENT=web,worker \
  -sERROR_ON_UNDEFINED_SYMBOLS=1 \
  -sEXPORTED_FUNCTIONS=_main \
  -sEXPORTED_RUNTIME_METHODS=ccall,cwrap \
  -sUSE_PTHREADS=1 \
  -pthread \
  -sPTHREAD_POOL_SIZE=4 \
  -sPROXY_TO_PTHREAD=1 \
  -gsource-map \
  --source-map-base "http://127.0.0.1:8000/" \
  -g \
  -o "${EXAMPLE_NAME}.html"

cd ..
echo ""
echo "✅ Build complete."
echo "📄 Output: ${WASM_BUILD_DIR}/${EXAMPLE_NAME}.html"
echo "🌐 Serving built assets..."
python3 serve.py
xdg-open http://localhost:8000/dealii_wasm_build/minimal_dealii.html