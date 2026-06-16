#!/bin/zsh
#
# Build a distributable release binary of MLXAudioServer.
#
# Usage:
#   ./scripts/build-release.sh [output_dir]
#
# The script:
#   1. Runs `swift build -c release`
#   2. Copies the binary and mlx.metallib to the output directory
#
# The mlx.metallib is required at runtime — MLX searches for it next to the
# binary first (see mlx-swift device.cpp load_colocated_library). SwiftPM does
# not compile Metal shaders, so we source the metallib from the Homebrew mlx
# formula (which must match the mlx-swift version).
#
# Output: <output_dir>/MLXAudioServer and <output_dir>/mlx.metallib
#

set -euo pipefail

OUTPUT_DIR="${1:-dist}"
# Resolve the script's directory (parent of scripts/)
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BINARY_NAME="MLXAudioServer"

echo "Building release binary..."
swift build -c release

BUILD_DIR="${SCRIPT_DIR}/.build/release"
BINARY_PATH="${BUILD_DIR}/${BINARY_NAME}"

if [[ ! -f "${BINARY_PATH}" ]]; then
    echo "error: release binary not found at ${BINARY_PATH}" >&2
    exit 1
fi

echo "Creating output directory: ${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

echo "Copying binary..."
cp -f "${BINARY_PATH}" "${OUTPUT_DIR}/${BINARY_NAME}"

# --- metallib ---
# MLX needs mlx.metallib at runtime. SwiftPM cannot compile Metal shaders.
# We look for a compatible metallib from the Homebrew mlx formula, or from
# a previous build's copy.
METALLIB_SRC=""

# Try Homebrew mlx formula first
HOMEBREW_METALLIB="/opt/homebrew/lib/mlx.metallib"
if [[ -f "${HOMEBREW_METALLIB}" ]]; then
    METALLIB_SRC="${HOMEBREW_METALLIB}"
fi

# Fallback: check if metallib already exists in the build dir
if [[ -z "${METALLIB_SRC}" && -f "${BUILD_DIR}/mlx.metallib" ]]; then
    METALLIB_SRC="${BUILD_DIR}/mlx.metallib"
fi

if [[ -n "${METALLIB_SRC}" ]]; then
    echo "Copying mlx.metallib from: ${METALLIB_SRC}"
    cp -f "${METALLIB_SRC}" "${OUTPUT_DIR}/mlx.metallib"
else
    echo "warning: mlx.metallib not found." >&2
    echo "  The server will fail at runtime with 'Failed to load the default metallib'." >&2
    echo "  Install the Homebrew mlx formula (brew install mlx) and re-run," >&2
    echo "  or copy mlx.metallib from a Python mlx installation next to the binary." >&2
fi

echo ""
echo "Build complete. Output in ${OUTPUT_DIR}/"
ls -lh "${OUTPUT_DIR}/"
echo ""
echo "To run:"
echo "  ${OUTPUT_DIR}/${BINARY_NAME} --model <model-repo> [--host 0.0.0.0] [--port 8000]"
