#!/bin/bash
set -euo pipefail

declare -A REPOS=(
  ["KOKKOS"]="https://github.com/kokkos/kokkos.git"
  ["OCC"]="https://git.dev.opencascade.org/repos/occt.git"
  ["DEAL_II"]="https://github.com/dealii/dealii.git"
  ["TASKFLOW"]="https://github.com/taskflow/taskflow.git"
  ["VTK"]="https://github.com/Kitware/VTK.git"
)

declare -A CURRENT_HASHES=(
  ["KOKKOS_COMMIT"]="3e7dfc68cc1fb371c345ef42cb0f0d97caee8b81"
  ["OCC_COMMIT"]="22d437b771eb322dcceec3ad0efec6876721b8a9"
  ["DEAL_II_COMMIT"]="0674a6cf7bf160eb634e37908173b59bb85af789"
  ["TASKFLOW_COMMIT"]="83591c4a5f55eb4f0d5760a508da34b7a11f71ee"
  ["VTK_COMMIT"]="1d0e7351b6b95fb74a65ee7ca6fe54870b0417a4"
)

if [[ "${1:-}" == "clean" || "${1:-}" == "--clean" || "${1:-}" == "-c" ]]; then
  echo "🧹 Cleaning build and dependency directories..."
  rm -rf external install dealii dealii_wasm_build native_build
  echo "✅ Clean complete."
  exit 0
fi

if [[ "${1:-}" == "update" || "${1:-}" == "--update" || "${1:-}" == "-u" ]]; then
  SCRIPT_FILE="${BASH_SOURCE[0]}"
  TMP_SCRIPT="${SCRIPT_FILE}.tmp"
  echo "🔍 Checking for newer commits..."

  UPDATE_NEEDED=false
  cp "$SCRIPT_FILE" "$TMP_SCRIPT"

  for var in "${!CURRENT_HASHES[@]}"; do
    repo_key="${var%_COMMIT}"
    repo_url="${REPOS[$repo_key]}"
    current_hash="${CURRENT_HASHES[$var]}"

    # Get latest commit from default branch
    latest_hash=$(git ls-remote "$repo_url" HEAD | awk '{print $1}')

    if [[ "$current_hash" != "$latest_hash" ]]; then
      echo "🆕 $repo_key: New commit available!"
      echo "   Old: $current_hash"
      echo "   New: $latest_hash"
      sed -i "s|^$var=.*|$var=\"$latest_hash\"|" "$TMP_SCRIPT"
      UPDATE_NEEDED=true
    else
      echo "✅ $repo_key: Up to date."
    fi
  done

  # Replace the script if needed
  if [ "$UPDATE_NEEDED" = true ]; then
    mv "$TMP_SCRIPT" "$SCRIPT_FILE"
    echo "✅ Script updated with latest commits."
    exit 0
  else
    rm "$TMP_SCRIPT"
  fi
  exit 0
fi

BOOST_VERSION="1.84.0"

ensure_git_checkout() {
  local repo_url="$1"
  local commit_hash="$2"
  local target_dir="$3"

  if [ -d "$target_dir" ]; then
    local current_commit
    current_commit=$(git -C "$target_dir" rev-parse HEAD 2>/dev/null || echo "")
    if [ "$current_commit" = "$commit_hash" ]; then
      echo "✅ Already cloned at commit ${commit_hash:0:10} → $target_dir"
      return
    else
      echo "⚠️ Commit mismatch in $target_dir"
      echo "   Found:    ${current_commit:0:10}"
      echo "   Expected: ${commit_hash:0:10}"
      echo "🧹 Removing old directory..."
      rm -rf "$target_dir"
    fi
  fi

  echo "📦 Cloning $repo_url at commit ${commit_hash:0:10}..."
  mkdir -p "$(dirname "$target_dir")"
  
  # Create a temporary global config to suppress hint paragraph about initial branch name.
  temp_gitconfig=$(mktemp)
  git config --file "$temp_gitconfig" init.defaultBranch master

  export GIT_CONFIG_GLOBAL="$temp_gitconfig"
  git init "$target_dir"
  unset GIT_CONFIG_GLOBAL
  rm -f "$temp_gitconfig"
  
  git -C "$target_dir" remote add origin "$repo_url"
  git -C "$target_dir" fetch --depth=1 origin "$commit_hash" --quiet
  git -C "$target_dir" checkout "$commit_hash" --quiet
}

# === Check for required tools ===
declare -A packages=(
    ["cmake"]="cmake"
    ["ccache"]="ccache"
    ["git"]="git"
    ["make"]="build-essential"
    ["ninja"]="ninja-build"
    ["jq"]="jq"
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

INSTALL_DIR="$(pwd)/install"
NATIVE_BUILD_DIR="native_build"
WASM_BUILD_DIR="dealii_wasm_build"
EXAMPLE_NAME="minimal_dealii"
THREADS=$(nproc)
START_DIR=$(pwd)

# === Setup Emscripten ===
if [ ! -d "emsdk" ]; then
  echo "📥 Cloning emsdk..."
  git clone https://github.com/emscripten-core/emsdk.git
fi

cd emsdk
git pull --quiet

# Extract latest upstream tag from local JSON
LATEST_VERSION=$(jq -r '.aliases.latest' emscripten-releases-tags.json)
# CURRENT_VERSION=$(./emsdk list | grep -E '^\s*\*' | awk '{print $2}')
CURRENT_VERSION=$(./emsdk list | grep 'INSTALLED' | awk '{print $1}' | head -n 1)

if [ -z "$CURRENT_VERSION" ] || [ "$CURRENT_VERSION" != "$LATEST_VERSION" ]; then
  ./emsdk install latest
  ./emsdk activate latest
fi

cd "$START_DIR"
source ./emsdk/emsdk_env.sh

# === VTK ===
VTK_DIR="external/vtk"
VTK_BUILD_DIR="$VTK_DIR/build"
VTK_INSTALL_DIR="$INSTALL_DIR/vtk"

ensure_git_checkout "${REPOS[VTK]}" "${CURRENT_HASHES[VTK_COMMIT]}" "$VTK_DIR"

mkdir -p "$VTK_BUILD_DIR"
cd "$VTK_BUILD_DIR"

echo "⚙️  Configuring VTK with Emscripten..."
# https://github.com/Kitware/VTK/blob/master/Documentation/docs/advanced/build_wasm_emscripten.md?plain=1#L65
emcmake cmake \
  -S .. \
  -B . \
  -G "Ninja" \
  -DCMAKE_INSTALL_PREFIX="$VTK_INSTALL_DIR" \
  -DBUILD_SHARED_LIBS:BOOL=OFF \
  -DVTK_ENABLE_LOGGING:BOOL=OFF \
  -DVTK_WRAP_JAVASCRIPT:BOOL=ON \
  -DVTK_WASM_OPTIMIZATION=LITTLE \
  -DVTK_MODULE_ENABLE_VTK_hdf5:STRING=NO \
  -DVTK_MODULE_ENABLE_VTK_RenderingContextOpenGL2:STRING=DONT_WANT \
  -DVTK_MODULE_ENABLE_VTK_RenderingCellGrid:STRING=NO \
  -DVTK_MODULE_ENABLE_VTK_sqlite:STRING=NO \
  -DCMAKE_C_FLAGS="-matomics -mbulk-memory -fwasm-exceptions" \
  -DCMAKE_CXX_FLAGS="-matomics -mbulk-memory -fwasm-exceptions" \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DCMAKE_BUILD_TYPE=Release

echo "🔨 Building VTK..."
ninja -j${THREADS}
ninja install
cd "$START_DIR"

# === Kokkos ===
KOKKOS_DIR="external/kokkos"
KOKKOS_INSTALL_DIR="$INSTALL_DIR/kokkos"

ensure_git_checkout "${REPOS[KOKKOS]}" "${CURRENT_HASHES[KOKKOS_COMMIT]}" "$KOKKOS_DIR"

mkdir -p "$KOKKOS_DIR/build"
cd "$KOKKOS_DIR/build"

emcmake cmake .. \
  -DCMAKE_INSTALL_PREFIX="$KOKKOS_INSTALL_DIR" \
  -DCMAKE_CXX_STANDARD=17 \
  -DKokkos_ENABLE_SERIAL=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DKOKKOS_IMPL_32BIT=ON \
  -DKokkos_ENABLE_DEPRECATED_CODE=OFF \
  -DCMAKE_CXX_FLAGS="-DKOKKOS_IMPL_32BIT -pthread -matomics -mbulk-memory -fwasm-exceptions" \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -G "Ninja"

ninja -j${THREADS}
ninja install
cd "$START_DIR"

if [ ! -f "$INSTALL_DIR/kokkos/lib/cmake/Kokkos/KokkosConfig.cmake" ]; then
  echo "❌ KokkosConfig.cmake not found. Kokkos install may have failed."
  exit 1
fi

# === OpenCASCADE ===
OCC_DIR="external/opencascade"
OCC_BUILD_DIR="$OCC_DIR/build"
OCC_INSTALL_DIR="$INSTALL_DIR/opencascade"
OCC_LIB_DIR="$OCC_INSTALL_DIR/lib"

ensure_git_checkout "${REPOS[OCC]}" "${CURRENT_HASHES[OCC_COMMIT]}" "$OCC_DIR"

mkdir -p "$OCC_BUILD_DIR"
cd "$OCC_BUILD_DIR"

echo "⚙️  Configuring OpenCASCADE with Emscripten..."
cmake .. \
  -DCMAKE_TOOLCHAIN_FILE="$(pwd)/../../../emsdk/upstream/emscripten/cmake/Modules/Platform/Emscripten.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$OCC_INSTALL_DIR" \
  -DBUILD_MODULE_ApplicationFramework=OFF \
  -DCMAKE_C_FLAGS="-sUSE_PTHREADS=1 -matomics -mbulk-memory -fwasm-exceptions" \
  -DCMAKE_CXX_FLAGS="-sUSE_PTHREADS=1 -matomics -mbulk-memory -fwasm-exceptions" \
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
  -DCMAKE_C_COMPILER_LAUNCHER=ccache \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \

echo "🔨 Building OpenCASCADE..."
emmake make -j${THREADS}
emmake make install
cd "$START_DIR"

# === deal.II ===
DEAL_II_DIR="dealii"

ensure_git_checkout ${REPOS[DEAL_II]} "${CURRENT_HASHES[DEAL_II_COMMIT]}" "$DEAL_II_DIR"

# === Patches ===
PATCH_FILE="$DEAL_II_DIR/cmake/modules/FindDEAL_II_OPENCASCADE.cmake"

if ! grep -q "🟢 Skipping OPENCASCADE find_library calls" "$PATCH_FILE"; then
  echo "🛠️  Patching $PATCH_FILE to skip find_library for OPENCASCADE_LIBRARIES..."

  sed -i '/foreach(_library ${_opencascade_libraries})/i \
if(OPENCASCADE_LIBRARIES AND OPENCASCADE_INCLUDE_DIR)\n\
  message(STATUS "🟢 Skipping OPENCASCADE find_library calls because OPENCASCADE_LIBRARIES was provided manually.")\n\
  process_feature(OPENCASCADE\n\
    LIBRARIES REQUIRED OPENCASCADE_LIBRARIES\n\
    INCLUDE_DIRS REQUIRED OPENCASCADE_INCLUDE_DIR\n\
  )\n\
  return()\n\
endif()\n' "$PATCH_FILE"

else
  echo "✅ Patch already applied to $PATCH_FILE"
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

OPENCASCADE_LIBRARIES=$(find "$OCC_INSTALL_DIR/lib" -name 'libTK*.a' | sort | tr '\n' ';')

# VTK 9.2+ no longer installs VTKConfig.cmake, only vtk-config.cmake.
# deal.II expects VTKConfig.cmake, so we create a symlink for compatibility.
VTK_CMAKE_DIR=$(find "$VTK_INSTALL_DIR/lib/cmake" -maxdepth 1 -type d -name "vtk-*" | head -n 1)
if [ -z "$VTK_CMAKE_DIR" ]; then
  echo "❌ Could not locate vtk-* CMake directory in $VTK_INSTALL_DIR/lib/cmake"
  exit 1
fi
if [ ! -f "$VTK_CMAKE_DIR/VTKConfig.cmake" ]; then
  echo "🔗 Creating VTKConfig.cmake → vtk-config.cmake symlink for deal.II compatibility"
  ln -sf vtk-config.cmake "$VTK_CMAKE_DIR/VTKConfig.cmake"
fi
VTK_DIR="$VTK_CMAKE_DIR"

# === Configure deal.II ===
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
  -DDEAL_II_WITH_VTK=ON \
  -DVTK_DIR="$VTK_DIR" \
  -DDEAL_II_WITH_ARBORX=OFF \
  -DDEAL_II_WITH_TBB=OFF \
  -DDEAL_II_WITH_KOKKOS=ON \
  -DKOKKOS_DIR="$KOKKOS_INSTALL_DIR/lib/cmake/Kokkos" \
  -DDEAL_II_FORCE_BUNDLED_TASKFLOW=ON \
  -DDEAL_II_TASKFLOW_BACKEND=Pool \
  -DCMAKE_CXX_FLAGS="-pthread -sUSE_PTHREADS=1 -DKOKKOS_IMPL_32BIT -fwasm-exceptions" \
  -DDEAL_II_BUILD_EXPAND_INSTANTIATIONS=OFF \
  -DDEAL_II_USE_PRECOMPILED_INSTANCES=ON \
  -DEXPAND_INSTANTIATIONS_EXE="$PWD/../$NATIVE_BUILD_DIR/bin/expand_instantiations" \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \

export PATH="$PWD/../$NATIVE_BUILD_DIR/bin:$PATH"
pwd
emmake make -j${THREADS}
cd "$START_DIR"

# === Boost ===
BOOST_DIR="external/boost"
BOOST_TARBALL="boost_${BOOST_VERSION//./_}.tar.gz" # Replace . with _
BOOST_URL="https://archives.boost.io/release/${BOOST_VERSION}/source/${BOOST_TARBALL}"
BOOST_JSON_URL="${BOOST_URL}.json"
VERSION_HEADER="${BOOST_DIR}/boost/version.hpp"

# Function to extract version from version.hpp
get_boost_version() {
  local header="$1"
  if [ ! -f "$header" ]; then
    echo ""
    return
  fi
  local version_num
  version_num=$(grep "#define BOOST_VERSION" "$header" | awk '{ print $3 }')
  local major=$((version_num / 100000))
  local minor=$(((version_num / 100) % 1000))
  local patch=$((version_num % 100))
  echo "${major}.${minor}.${patch}"
}

NEEDS_DOWNLOAD=1

if [ -d "$BOOST_DIR/boost" ]; then
  INSTALLED_VERSION=$(get_boost_version "$VERSION_HEADER")
  if [ "$INSTALLED_VERSION" = "$BOOST_VERSION" ]; then
    NEEDS_DOWNLOAD=0
    echo "✅ Boost ${BOOST_VERSION} already exists at ${BOOST_DIR}"
  else
    echo "⚠️ Boost directory exists but version mismatch: found ${INSTALLED_VERSION}, expected ${BOOST_VERSION}"
    echo "🧹 Removing old Boost directory..."
    rm -rf "$BOOST_DIR"
  fi
fi

if [ "$NEEDS_DOWNLOAD" -eq 1 ]; then
  echo "📦 Downloading Boost ${BOOST_VERSION}..."
  mkdir -p external
  wget -q --show-progress "$BOOST_URL" -O "external/${BOOST_TARBALL}" || curl -L "$BOOST_URL" -o "external/${BOOST_TARBALL}"

  # Download and parse checksum
  echo "🔐 Verifying checksum..."
  CHECKSUM=$(curl -s "$BOOST_JSON_URL" | grep -o '"sha256": *"[^"]*"' | sed 's/.*"sha256": *"\([^"]*\)"/\1/')

  if [ -z "$CHECKSUM" ]; then
    echo "❌ Failed to retrieve checksum from JSON."
    exit 1
  fi

  ACTUAL=$(sha256sum "external/${BOOST_TARBALL}" | awk '{ print $1 }')

  if [ "$ACTUAL" != "$CHECKSUM" ]; then
    echo "❌ Checksum verification failed!"
    echo "Expected: $CHECKSUM"
    echo "Actual:   $ACTUAL"
    exit 1
  else
    echo "✅ Checksum verification passed."
  fi

  echo "📦 Extracting Boost..."
  tar -xf "external/${BOOST_TARBALL}" -C external
  mv "external/boost_${BOOST_VERSION//./_}" "$BOOST_DIR"
  rm -f "external/${BOOST_TARBALL}"
  
  echo "📦 Bootstrapping Boost headers..."
  cd "$BOOST_DIR"
  ./bootstrap.sh
  ./b2 headers
  if [ $? -ne 0 ]; then
    echo "❌ Boost header generation failed."
    exit 1
  fi
  cd ..
fi

# === Taskflow ===
TASKFLOW_DIR="external/taskflow"

ensure_git_checkout "${REPOS[TASKFLOW]}" "${CURRENT_HASHES[TASKFLOW_COMMIT]}" "$TASKFLOW_DIR"

# === Minimal example ===
cat > "$WASM_BUILD_DIR/${EXAMPLE_NAME}.cc" <<EOF
#include <deal.II/base/point.h>
#include <deal.II/opencascade/utilities.h>
#include <deal.II/vtk/utilities.h>

#include <BRepPrimAPI_MakeBox.hxx>
#include <iostream>
#include <string>

int main()
{
  using namespace dealii;
  const std::string cad_file_name = "/res/h_press.stl";
  TopoDS_Shape model_shape = OpenCASCADE::read_STL(cad_file_name);
  std::cout << " Read " << cad_file_name << std::endl;
  const double tolerance = OpenCASCADE::get_shape_tolerance(model_shape) * 5;

  TopoDS_Shape shape = BRepPrimAPI_MakeBox(1.0, 1.0, 1.0).Shape();
  std::cout << "✅ OCC shape created.\n";

  Point<3> query(1.2, 0.5, 0.5);
  const double tol = 1e-6;

  Point<3> closest = OpenCASCADE::closest_point(shape, query, tol);
  std::cout << "Query point:   " << query << "\n";
  std::cout << "Closest point: " << closest << "\n";

  auto vtk_array = VTKWrappers::dealii_point_to_vtk_array(query);
  std::cout << "✅ VTK array created from Point<3>: ";
  for (int i = 0; i < vtk_array->GetNumberOfComponents(); ++i)
    std::cout << vtk_array->GetComponent(0, i) << " ";
  std::cout << "\n";
  return 0;
}
EOF

cd "$WASM_BUILD_DIR"
# === Compile example to WebAssembly ===
em++ -O1 "${EXAMPLE_NAME}.cc" \
  --preload-file ../res \
 ./lib/libdeal_II.a \
  $(find "$OCC_INSTALL_DIR/lib" -name 'libTK*.a' | sort | xargs) \
  $(find "$VTK_INSTALL_DIR/lib" -name 'libvtk*.a' | sort | xargs) \
  "$INSTALL_DIR/kokkos/lib/libkokkoscontainers.a" \
  "$INSTALL_DIR/kokkos/lib/libkokkoscore.a" \
  -I"$START_DIR/dealii/include" \
  -I"$START_DIR/dealii/bundled/taskflow-3.10.0" \
  -I./include \
  -I"$INSTALL_DIR/kokkos/include" \
  -I"$INSTALL_DIR/opencascade/include/opencascade" \
  -I"$INSTALL_DIR/opencascade/include" \
  -I"$INSTALL_DIR/vtk/include/vtk-9.5" \
  -I"$START_DIR/external/boost" \
  -I"$START_DIR/external/taskflow" \
  -std=c++17 \
  -sASSERTIONS=2 \
  -sINITIAL_MEMORY=2048MB \
  -sEXIT_RUNTIME=1 \
  -sENVIRONMENT=web,worker \
  -sERROR_ON_UNDEFINED_SYMBOLS=1 \
  -sEXPORTED_FUNCTIONS=_main \
  -sEXPORTED_RUNTIME_METHODS=ccall,cwrap \
  -fwasm-exceptions \
  -sUSE_PTHREADS=1 \
  -pthread \
  -sPTHREAD_POOL_SIZE=4 \
  -sPROXY_TO_PTHREAD=1 \
  -sMODULARIZE=1 \
  -sEXPORT_ES6=1 \
  -gsource-map \
  --source-map-base "http://127.0.0.1:8000/" \
  -g \
  -o "${EXAMPLE_NAME}.html"

echo ""
echo "✅ Build complete."
echo "📄 Output: ${WASM_BUILD_DIR}/${EXAMPLE_NAME}.html"
echo "🌐 Serving built assets..."
cd ..

# Start the server in the background
python3 serve.py > /dev/null 2>&1 &
server_pid=$!

# Ensure cleanup on exit
trap 'kill "$server_pid" 2>/dev/null || true' EXIT

# Wait for the server to become available
echo "⏳ Waiting for server on http://localhost:8000..."
for i in {1..50}; do
  if curl -s --head http://localhost:8000/ | grep -q "200 OK"; then
    echo "✅ Server is up!"
    break
  fi
  sleep 0.1
done

# Launch browser
url="http://localhost:8000/dealii_wasm_build/minimal_dealii.html"
if [ "$(systemd-detect-virt)" = "wsl" ]; then
  powershell.exe /C "Start-Process $url"
else
  xdg-open "$url"
fi

# Wait for manual Ctrl+C to exit
wait "$server_pid"