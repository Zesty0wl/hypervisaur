#!/usr/bin/env zsh

# Builds the Hypervisaur agent for Windows on ARM, which runs programs in Windows virtual machines for the Mac.
#
# The agent is built from agent.c with llvm-mingw, which is downloaded at the version below and verified, and replaces the
# agent in ARM64. The agent is kept in the repository so that building the app doesn't need the toolchain.
#
# Usage: WindowsGuestAgent/build.sh [work directory]
# The work directory defaults to a temporary directory that's removed afterwards.

set -euo pipefail

LLVM_MINGW_VERSION="20261006"
LLVM_MINGW_SHA256="a7a19b11048e89372637d26279cdb7c430ed3cf8c1e224310421312bf986ebf6"

TARGET="aarch64-w64-mingw32"

AGENT_DIR="${0:A:h}"
OUTPUT_DIR="$AGENT_DIR/ARM64"

if [[ $# -gt 0 ]]; then
    WORK_DIR="${1:A}"
    mkdir -p "$WORK_DIR"
else
    WORK_DIR="$(mktemp -d -t HypervisaurGuestAgent)"
    trap 'rm -rf "$WORK_DIR"' EXIT
fi

LLVM_MINGW_NAME="llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal"
ARCHIVE="$WORK_DIR/$LLVM_MINGW_NAME.tar.xz"

if [[ ! -d "$WORK_DIR/$LLVM_MINGW_NAME" ]]; then
    echo "Downloading llvm-mingw $LLVM_MINGW_VERSION"
    if [[ ! -f "$ARCHIVE" ]]; then
        curl -fsSL --retry 3 -o "$ARCHIVE.download" "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VERSION/$LLVM_MINGW_NAME.tar.xz"
        mv "$ARCHIVE.download" "$ARCHIVE"
    fi
    if ! echo "$LLVM_MINGW_SHA256  $ARCHIVE" | shasum -a 256 -c --status; then
        echo "error: $ARCHIVE doesn't match its expected checksum." >&2
        exit 1
    fi
    tar -xf "$ARCHIVE" -C "$WORK_DIR"
fi

echo "Building the agent"
mkdir -p "$OUTPUT_DIR"

# Builds are reproducible: nothing depends on when or where the agent was built.
"$WORK_DIR/$LLVM_MINGW_NAME/bin/$TARGET-clang" \
    -municode -std=c11 -O2 -Wall -Wextra -Werror \
    -D_WIN32_WINNT=0x0A00 -DNTDDI_VERSION=0x0A000006 \
    -ffile-prefix-map="$AGENT_DIR=." \
    -static -s -Wl,--no-insert-timestamp \
    -o "$OUTPUT_DIR/HypervisaurAgent.exe" \
    "$AGENT_DIR/agent.c" \
    -lole32 -lshell32 -luser32 -lwtsapi32 -luserenv -ladvapi32 -lbcrypt -lmpr

echo "Built the agent in $OUTPUT_DIR"
shasum -a 256 "$OUTPUT_DIR/HypervisaurAgent.exe"
