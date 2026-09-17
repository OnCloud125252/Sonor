#!/usr/bin/env bash
#
# Build the sonor.cpp static libraries that the Sonor app links.
#
# Xcode runs this as a build phase. You can also run it by hand:
#
#   scripts/build-engine.sh            build if the libraries are missing or stale
#   scripts/build-engine.sh --clean    delete the build directory first
#
# The build stays static on purpose. A shared build makes the app load
# libggml*.dylib from this source tree, so the app only runs on this machine.
#
set -euo pipefail

# ---------------------------------------------------------------- style ----

_CLI_RED='\033[0;31m'
_CLI_GREEN='\033[0;32m'
_CLI_YELLOW='\033[0;33m'
_CLI_CYAN='\033[0;36m'
_CLI_NC='\033[0m'

if [[ -n "${CLICOLOR_FORCE:-}" ]]; then
  :
elif [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
  _CLI_RED='' _CLI_GREEN='' _CLI_YELLOW='' _CLI_CYAN='' _CLI_NC=''
fi

_CLI_CHECK="${_CLI_GREEN}[✓]${_CLI_NC}"
_CLI_CROSS="${_CLI_RED}[✗]${_CLI_NC}"
_CLI_WARN="${_CLI_YELLOW}[!]${_CLI_NC}"
_CLI_INFO="${_CLI_CYAN}[i]${_CLI_NC}"

log_info()    { echo -e "$_CLI_INFO $1"; }
log_success() { echo -e "$_CLI_CHECK $1"; }
log_warn()    { echo -e "$_CLI_WARN $1"; }
log_error()   { echo -e "$_CLI_CROSS $1"; }

# ------------------------------------------------------------- settings ----

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_DIR="$REPO_ROOT/sonor.cpp"
BUILD_DIR="$ENGINE_DIR/build"
PROJECT_FILE="$REPO_ROOT/Sonor.xcodeproj/project.pbxproj"

# The engine must not target a newer system than the app. Xcode exports the
# value during a build phase. A manual run reads it from the project instead.
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-}"
if [[ -z "$DEPLOYMENT_TARGET" ]]; then
  DEPLOYMENT_TARGET=$(grep -m 1 -o 'MACOSX_DEPLOYMENT_TARGET = [0-9.]*' "$PROJECT_FILE" | awk '{print $3}')
fi

# Every library the Xcode target links.
LIBRARIES=(
  "src/libsonor.a"
  "ggml/src/libggml.a"
  "ggml/src/libggml-base.a"
  "ggml/src/libggml-cpu.a"
  "ggml/src/ggml-metal/libggml-metal.a"
  "ggml/src/ggml-blas/libggml-blas.a"
)

CMAKE_OPTIONS=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
  -DBUILD_SHARED_LIBS=OFF
  -DGGML_METAL=ON
  -DGGML_METAL_EMBED_LIBRARY=ON
  -DGGML_BLAS=ON
  -DGGML_BLAS_VENDOR=Apple
  -DSONOR_BUILD_EXAMPLES=OFF
  -DSONOR_BUILD_TESTS=OFF
  -DSONOR_BUILD_SERVER=OFF
)

# ---------------------------------------------------------------- flags ----

if [[ "${1:-}" == "--clean" ]]; then
  log_info "Remove $BUILD_DIR"
  rm -rf "$BUILD_DIR"
fi

# --------------------------------------------------------------- checks ----

if ! command -v cmake >/dev/null 2>&1; then
  log_error "cmake not found."
  log_info "Install it with: brew install cmake"
  exit 1
fi

if [[ -z "$DEPLOYMENT_TARGET" ]]; then
  log_error "Cannot read MACOSX_DEPLOYMENT_TARGET from $PROJECT_FILE"
  exit 1
fi

# ----------------------------------------------------------- up to date ----

# The libraries are current when each one exists, and when no source file is
# newer than the oldest of them.
engine_is_current() {
  local library
  for library in "${LIBRARIES[@]}"; do
    [[ -f "$BUILD_DIR/$library" ]] || return 1
  done

  local newer
  newer=$(find "$ENGINE_DIR/src" "$ENGINE_DIR/include" "$ENGINE_DIR/ggml" \
            -type f \
            \( -name '*.c' -o -name '*.cpp' -o -name '*.h' -o -name '*.hpp' \
               -o -name '*.m' -o -name '*.metal' -o -name 'CMakeLists.txt' \) \
            -newer "$BUILD_DIR/${LIBRARIES[0]}" -print -quit 2>/dev/null) || true
  [[ -z "$newer" ]]
}

if engine_is_current; then
  log_success "sonor.cpp libraries are up to date"
  exit 0
fi

# --------------------------------------------------------------- build ----

if [[ ! -f "$BUILD_DIR/CMakeCache.txt" ]]; then
  log_info "Configure sonor.cpp (static, Metal, Accelerate, macOS $DEPLOYMENT_TARGET)"
  cmake -S "$ENGINE_DIR" -B "$BUILD_DIR" "${CMAKE_OPTIONS[@]}" >/dev/null
fi

log_info "Build sonor.cpp (the first build takes a few minutes)"
if ! cmake --build "$BUILD_DIR" -j"$(sysctl -n hw.ncpu)"; then
  log_error "sonor.cpp build failed"
  log_info "Run 'scripts/build-engine.sh --clean' to start over"
  exit 1
fi

# -------------------------------------------------------------- verify ----

missing=0
for library in "${LIBRARIES[@]}"; do
  if [[ ! -f "$BUILD_DIR/$library" ]]; then
    log_error "missing: $library"
    missing=1
  fi
done

if (( missing )); then
  exit 1
fi

stale_dylib=$(find "$BUILD_DIR" -name '*.dylib' -print -quit 2>/dev/null) || true
if [[ -n "$stale_dylib" ]]; then
  log_warn "The build directory still holds .dylib files from an older build."
  log_info "Run 'scripts/build-engine.sh --clean' to remove them."
fi

log_success "sonor.cpp libraries ready"
