#!/bin/zsh
#
# Build a distributable release binary of MLXAudioServer.
#
# Usage:
#   ./scripts/build-release.sh [output_dir]
#
# Builds via xcodebuild (not swift build) because SwiftPM cannot compile
# MLX's Metal shaders. Xcode compiles the .metal kernels and bundles the
# resulting default.metallib inside mlx-swift_Cmlx.bundle, which MLX finds
# automatically at runtime via the SwiftPM bundle search path.
#
# Output: <output_dir>/MLXAudioServer + mlx-swift_Cmlx.bundle/
#

set -euo pipefail

OUTPUT_DIR="${1:-dist}"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BINARY_NAME="MLXAudioServer"

echo "Building release binary with xcodebuild..."
xcodebuild build \
    -scheme "${BINARY_NAME}" \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "${SCRIPT_DIR}/.build/xcode" \
    -quiet \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_CODE_COVERAGE=NO

BUILD_DIR="${SCRIPT_DIR}/.build/xcode/Build/Products/Release"
BINARY_PATH="${BUILD_DIR}/${BINARY_NAME}"

if [[ ! -f "${BINARY_PATH}" ]]; then
    echo "error: release binary not found at ${BINARY_PATH}" >&2
    exit 1
fi

echo "Creating output directory: ${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

echo "Copying binary..."
cp -f "${BINARY_PATH}" "${OUTPUT_DIR}/${BINARY_NAME}"

echo "Copying mlx-swift_Cmlx.bundle (contains compiled Metal shaders)..."
cp -R "${BUILD_DIR}/mlx-swift_Cmlx.bundle" "${OUTPUT_DIR}/"

echo ""
echo "Build complete. Output in ${OUTPUT_DIR}/"
ls -lhR "${OUTPUT_DIR}/"
echo ""
echo "To run:"
echo "  ${OUTPUT_DIR}/${BINARY_NAME} --model <model-repo> [--host 0.0.0.0] [--port 8000]"
