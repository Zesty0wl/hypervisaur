#!/usr/bin/env zsh

# Builds the SPICE agent that shares the clipboard with Windows virtual machines, for Windows on ARM.
#
# The agent is built from https://gitlab.freedesktop.org/spice/win32/vd_agent with the patches in Patches, using llvm-mingw,
# and replaces the agent in ARM64. Everything is downloaded at the versions below and verified, so that the agent can be
# built again from the same sources. The agent is kept in the repository so that building the app doesn't need any of this.
#
# Usage: WindowsSPICEAgent/build.sh [work directory]
# The work directory defaults to a temporary directory that's removed afterwards.

set -euo pipefail

LLVM_MINGW_VERSION="20261006"
LLVM_MINGW_SHA256="a7a19b11048e89372637d26279cdb7c430ed3cf8c1e224310421312bf986ebf6"

ZLIB_VERSION="1.3.2"
ZLIB_SHA256="d7a0654783a4da529d1bb793b7ad9c3318020af77667bcae35f95d0e42a792f3"

LIBPNG_TAG="v1.6.59"
LIBPNG_COMMIT="cd952f49f95bb27154ae77dbb103032d95f6e580"

VD_AGENT_COMMIT="9c573c97545db8a58f1cc115f40073ea493bb356"
SPICE_COMMON_COMMIT="05c0c26839e88e6d0cc5452f49c40e38543c8f97"
SPICE_PROTOCOL_COMMIT="ce0c4211e6f16c66477934cc42e70fa0988ca7f0"

# The agent is licensed under the GPL, version 2 or later, but its repository doesn't include the license.
GPL_URL="https://www.gnu.org/licenses/old-licenses/gpl-2.0.txt"
GPL_SHA256="edaef632cbb643e4e7a221717a6c441a4c1a7c918e6e4d56debc3d8739b233f6"

TARGET="aarch64-w64-mingw32"

AGENT_DIR="${0:A:h}"
OUTPUT_DIR="$AGENT_DIR/ARM64"

if [[ $# -gt 0 ]]; then
    WORK_DIR="${1:A}"
    mkdir -p "$WORK_DIR"
else
    WORK_DIR="$(mktemp -d -t HypervisaurSPICEAgent)"
    trap 'rm -rf "$WORK_DIR"' EXIT
fi

for tool in cmake git curl shasum; do
    if ! command -v "$tool" >/dev/null; then
        echo "error: $tool is needed to build the SPICE agent." >&2
        exit 1
    fi
done

# Downloads a file unless it's already there, and checks that it's the expected one.
download() {
    local url="$1" sha256="$2" destination="$3"

    if [[ ! -f "$destination" ]]; then
        curl -fsSL --retry 3 -o "$destination.download" "$url"
        mv "$destination.download" "$destination"
    fi

    if ! echo "$sha256  $destination" | shasum -a 256 -c --status; then
        echo "error: $destination doesn't match its expected checksum." >&2
        exit 1
    fi
}

# Clones a repository at a commit, and checks that the commit is the expected one.
checkout() {
    local url="$1" commit="$2" destination="$3"

    if [[ ! -d "$destination/.git" ]]; then
        git init -q "$destination"
        git -C "$destination" remote add origin "$url"
    fi

    git -C "$destination" fetch -q --no-recurse-submodules --depth 1 origin "$commit"
    git -C "$destination" checkout -q --force "$commit"
    git -C "$destination" clean -q -fdx

    if [[ "$(git -C "$destination" rev-parse HEAD)" != "$commit" ]]; then
        echo "error: $url didn't check out at $commit." >&2
        exit 1
    fi
}

SOURCES_DIR="$WORK_DIR/sources"
BUILD_DIR="$WORK_DIR/build"
PREFIX="$WORK_DIR/prefix"
mkdir -p "$SOURCES_DIR"
rm -rf "$BUILD_DIR" "$PREFIX"

echo "Downloading llvm-mingw $LLVM_MINGW_VERSION"
LLVM_MINGW_NAME="llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal"
download "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VERSION/$LLVM_MINGW_NAME.tar.xz" \
    "$LLVM_MINGW_SHA256" "$SOURCES_DIR/$LLVM_MINGW_NAME.tar.xz"
if [[ ! -d "$WORK_DIR/$LLVM_MINGW_NAME" ]]; then
    tar -xf "$SOURCES_DIR/$LLVM_MINGW_NAME.tar.xz" -C "$WORK_DIR"
fi
TOOLCHAIN="$WORK_DIR/$LLVM_MINGW_NAME/bin"

echo "Downloading zlib $ZLIB_VERSION"
download "https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.xz" \
    "$ZLIB_SHA256" "$SOURCES_DIR/zlib-$ZLIB_VERSION.tar.xz"
rm -rf "$SOURCES_DIR/zlib-$ZLIB_VERSION"
tar -xf "$SOURCES_DIR/zlib-$ZLIB_VERSION.tar.xz" -C "$SOURCES_DIR"

echo "Downloading libpng $LIBPNG_TAG"
checkout "https://github.com/pnggroup/libpng.git" "$LIBPNG_COMMIT" "$SOURCES_DIR/libpng"

echo "Downloading the SPICE agent"
checkout "https://gitlab.freedesktop.org/spice/win32/vd_agent.git" "$VD_AGENT_COMMIT" "$SOURCES_DIR/vd_agent"
checkout "https://gitlab.freedesktop.org/spice/spice-common.git" "$SPICE_COMMON_COMMIT" "$SOURCES_DIR/vd_agent/spice-common"
checkout "https://gitlab.freedesktop.org/spice/spice-protocol.git" "$SPICE_PROTOCOL_COMMIT" "$SOURCES_DIR/vd_agent/spice-protocol"

# The agent's version comes from its tags, which a shallow clone doesn't have.
git -C "$SOURCES_DIR/vd_agent" fetch -q --no-recurse-submodules --unshallow --tags origin

download "$GPL_URL" "$GPL_SHA256" "$SOURCES_DIR/gpl-2.0.txt"

# Patches are kept in a folder named after the repository they apply to: the agent, or one of its submodules.
for repository in "$AGENT_DIR/Patches/"*(/N); do
    if [[ "${repository:t}" == "vd_agent" ]]; then
        repository_dir="$SOURCES_DIR/vd_agent"
    else
        repository_dir="$SOURCES_DIR/vd_agent/${repository:t}"
    fi

    for patch in "$repository/"*.patch(N); do
        echo "Applying ${repository:t}/${patch:t}"
        git -C "$repository_dir" apply --whitespace=nowarn "$patch"
    done
done

# Builds are reproducible: nothing depends on when or where the agent was built.
export SOURCE_DATE_EPOCH="$(git -C "$SOURCES_DIR/vd_agent" log -1 --format=%ct)"
COMMON_FLAGS="-ffile-prefix-map=$WORK_DIR=."

CMAKE_ARGS=(
    --no-warn-unused-cli
    -DCMAKE_SYSTEM_NAME=Windows
    -DCMAKE_SYSTEM_PROCESSOR=ARM64
    -DCMAKE_C_COMPILER="$TOOLCHAIN/$TARGET-clang"
    -DCMAKE_CXX_COMPILER="$TOOLCHAIN/$TARGET-clang++"
    -DCMAKE_RC_COMPILER="$TOOLCHAIN/$TARGET-windres"
    -DCMAKE_AR="$TOOLCHAIN/llvm-ar"
    -DCMAKE_RANLIB="$TOOLCHAIN/llvm-ranlib"
    -DCMAKE_C_FLAGS="$COMMON_FLAGS"
    -DCMAKE_CXX_FLAGS="$COMMON_FLAGS"
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,--no-insert-timestamp"
    -DCMAKE_FIND_ROOT_PATH="$PREFIX"
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
    -DCMAKE_INSTALL_PREFIX="$PREFIX"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
)

echo "Building zlib"
cmake -S "$SOURCES_DIR/zlib-$ZLIB_VERSION" -B "$BUILD_DIR/zlib" "${CMAKE_ARGS[@]}" \
    -DZLIB_BUILD_SHARED=OFF -DZLIB_BUILD_TESTING=OFF >/dev/null
cmake --build "$BUILD_DIR/zlib" --parallel >/dev/null
cmake --install "$BUILD_DIR/zlib" >/dev/null

# zlib names its static library differently from what CMake looks for.
ZLIB_ARGS=(-DZLIB_LIBRARY="$PREFIX/lib/libzs.a" -DZLIB_INCLUDE_DIR="$PREFIX/include")

echo "Building libpng"
cmake -S "$SOURCES_DIR/libpng" -B "$BUILD_DIR/libpng" "${CMAKE_ARGS[@]}" \
    "${ZLIB_ARGS[@]}" -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_FRAMEWORK=OFF >/dev/null
cmake --build "$BUILD_DIR/libpng" --parallel >/dev/null
cmake --install "$BUILD_DIR/libpng" >/dev/null

echo "Building the SPICE agent"
cmake -S "$SOURCES_DIR/vd_agent" -B "$BUILD_DIR/vd_agent" "${CMAKE_ARGS[@]}" "${ZLIB_ARGS[@]}" >/dev/null
cmake --build "$BUILD_DIR/vd_agent" --parallel --target vdagent vdservice >/dev/null

AGENT_VERSION="$(git -C "$SOURCES_DIR/vd_agent" describe --abbrev=4 --match='v*' HEAD)"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
for executable in vdagent.exe vdservice.exe; do
    cp "$BUILD_DIR/vd_agent/$executable" "$OUTPUT_DIR/$executable"
done

# The licenses and sources go wherever the agent does, since it's distributed under the GPL and includes zlib and libpng.
cp "$SOURCES_DIR/gpl-2.0.txt" "$OUTPUT_DIR/COPYING.txt"
cp "$SOURCES_DIR/zlib-$ZLIB_VERSION/LICENSE" "$OUTPUT_DIR/zlib-LICENSE.txt"
cp "$SOURCES_DIR/libpng/LICENSE" "$OUTPUT_DIR/libpng-LICENSE.txt"
cat > "$OUTPUT_DIR/SOURCES.txt" <<EOF
SPICE agent for Windows on ARM, built by Hypervisaur

The agent is free software, licensed under the GNU General Public License, version 2 or later. See COPYING.txt.
It includes zlib and libpng, which are licensed under the licenses in zlib-LICENSE.txt and libpng-LICENSE.txt.

It was built with llvm-mingw $LLVM_MINGW_VERSION from these sources:

SPICE agent $AGENT_VERSION: https://gitlab.freedesktop.org/spice/win32/vd_agent, commit $VD_AGENT_COMMIT
spice-common: https://gitlab.freedesktop.org/spice/spice-common, commit $SPICE_COMMON_COMMIT
spice-protocol: https://gitlab.freedesktop.org/spice/spice-protocol, commit $SPICE_PROTOCOL_COMMIT
zlib $ZLIB_VERSION: https://github.com/madler/zlib
libpng $LIBPNG_TAG: https://github.com/pnggroup/libpng, commit $LIBPNG_COMMIT

The patches applied to them, and the script that builds the agent, are in the WindowsSPICEAgent folder of
https://github.com/Zesty0wl/hypervisaur.
EOF
for text in "$OUTPUT_DIR/"*.txt; do
    sed -i '' $'s/\r*$/\r/' "$text"
done

echo "Built the SPICE agent $AGENT_VERSION in $OUTPUT_DIR"
shasum -a 256 "$OUTPUT_DIR/"*.exe
