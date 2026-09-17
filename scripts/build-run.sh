#!/usr/bin/env bash
#
# Build Sonor, show where the app landed, and start it.
#
# Usage:
#   scripts/build-run.sh                 build Debug and start the app
#   scripts/build-run.sh --release       build Release instead
#   scripts/build-run.sh --build-only    build, do not start the app
#   scripts/build-run.sh --test          run the unit tests after the build
#   scripts/build-run.sh --clean         clean before the build
#   scripts/build-run.sh --permissions   open the Accessibility settings pane
#
set -euo pipefail

# ---------------------------------------------------------------- style ----

_CLI_RED='\033[0;31m'
_CLI_GREEN='\033[0;32m'
_CLI_YELLOW='\033[0;33m'
_CLI_BLUE='\033[0;34m'
_CLI_PURPLE='\033[0;35m'
_CLI_CYAN='\033[0;36m'
_CLI_GRAY='\033[0;90m'
_CLI_NC='\033[0m'

if [[ -n "${CLICOLOR_FORCE:-}" ]]; then
  :
elif [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
  _CLI_RED='' _CLI_GREEN='' _CLI_YELLOW='' _CLI_BLUE=''
  _CLI_PURPLE='' _CLI_CYAN='' _CLI_GRAY='' _CLI_NC=''
fi

_CLI_CHECK="${_CLI_GREEN}[✓]${_CLI_NC}"
_CLI_CROSS="${_CLI_RED}[✗]${_CLI_NC}"
_CLI_WARN="${_CLI_YELLOW}[!]${_CLI_NC}"
_CLI_INFO="${_CLI_CYAN}[i]${_CLI_NC}"

_CLI_WIDTH="${COLUMNS:-$( (tput cols </dev/tty) 2>/dev/null || tput cols 2>/dev/null || echo 80)}"
if (( _CLI_WIDTH > 92 )); then
  _CLI_WIDTH=92
fi

log_info()    { echo -e "$_CLI_INFO $1"; }
log_success() { echo -e "$_CLI_CHECK $1"; }
log_warn()    { echo -e "$_CLI_WARN $1"; }
log_error()   { echo -e "$_CLI_CROSS $1"; }

print_divider() {
  local color="${1:-$_CLI_PURPLE}"
  local label="${2:-}"
  local fill
  local padding
  if [[ -n "$label" ]]; then
    padding=$((_CLI_WIDTH - ${#label} - 6))
    (( padding < 0 )) && padding=0
    printf -v fill '%*s' "$padding" ''
    printf '%b━━━━[%s]%s%b\n' "$color" "$label" "${fill// /━}" "$_CLI_NC"
  else
    printf -v fill '%*s' "$_CLI_WIDTH" ''
    printf '%b%s%b\n' "$color" "${fill// /━}" "$_CLI_NC"
  fi
}

print_field() {
  printf "  %-15s ${_CLI_BLUE}%s${_CLI_NC}\n" "$1" "$2"
}

# ------------------------------------------------------------- settings ----

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$PROJECT_DIR/Sonor.xcodeproj"
SCHEME="Sonor"
CONFIGURATION="Debug"
START_APP=1
RUN_TESTS=0
CLEAN_FIRST=0

usage() {
  sed -n '3,11p' "${BASH_SOURCE[0]}" | sed 's/^#\{1\} \{0,1\}//'
}

open_permissions_pane() {
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
}

while (( $# )); do
  case "$1" in
    --release)     CONFIGURATION="Release" ;;
    --debug)       CONFIGURATION="Debug" ;;
    --build-only)  START_APP=0 ;;
    --test)        RUN_TESTS=1 ;;
    --clean)       CLEAN_FIRST=1 ;;
    --permissions) open_permissions_pane; exit 0 ;;
    -h|--help)     usage; exit 0 ;;
    *)
      log_error "Unknown option: ${_CLI_CYAN}$1${_CLI_NC}"
      echo ""
      usage
      exit 2
      ;;
  esac
  shift
done

if [[ ! -d "$PROJECT" ]]; then
  log_error "No project at ${_CLI_BLUE}$PROJECT${_CLI_NC}"
  exit 1
fi

XCODEBUILD_ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination 'platform=macOS'
)

if command -v xcbeautify >/dev/null 2>&1; then
  # --quiet keeps only tasks with a warning or an error.
  # --disable-logging drops the xcbeautify version banner.
  FORMATTER=(xcbeautify --quiet --disable-logging)
else
  # No formatter installed, so keep only the lines that matter.
  FORMATTER=(sed -n -E '/error:|warning:|\*\* (BUILD|TEST)/p')
fi

BUILD_LOG="$(mktemp -t sonor-build)"

show_log_errors() {
  local found
  found="$(grep -E "error:" "$BUILD_LOG" | sort -u | head -20 || true)"
  if [[ -n "$found" ]]; then
    echo ""
    while IFS= read -r line; do
      echo -e "    ${_CLI_RED}${line}${_CLI_NC}"
    done <<<"$found"
  fi
  echo ""
  log_info "Full log: ${_CLI_BLUE}$BUILD_LOG${_CLI_NC}"
}

# ----------------------------------------------------------------- head ----

echo ""
print_divider "$_CLI_PURPLE" "Sonor Build"
echo ""
print_field "Scheme:" "$SCHEME"
print_field "Configuration:" "$CONFIGURATION"
print_field "Project:" "$PROJECT"
echo ""

# ---------------------------------------------------------------- clean ----

if (( CLEAN_FIRST )); then
  log_info "Clean..."
  if xcodebuild "${XCODEBUILD_ARGS[@]}" clean >"$BUILD_LOG" 2>&1; then
    log_success "Clean done"
  else
    log_error "Clean failed"
    show_log_errors
    exit 1
  fi
  echo ""
fi

# ---------------------------------------------------------------- build ----

log_info "Build... ${_CLI_GRAY}(a first build takes a few minutes)${_CLI_NC}"
BUILD_START=$SECONDS

if xcodebuild "${XCODEBUILD_ARGS[@]}" build 2>&1 | tee "$BUILD_LOG" | "${FORMATTER[@]}"; then
  log_success "Build succeeded ${_CLI_GRAY}($((SECONDS - BUILD_START))s)${_CLI_NC}"
else
  log_error "Build failed ${_CLI_GRAY}($((SECONDS - BUILD_START))s)${_CLI_NC}"
  show_log_errors
  exit 1
fi

# ----------------------------------------------------------------- info ----

SETTINGS="$(xcodebuild "${XCODEBUILD_ARGS[@]}" -showBuildSettings 2>/dev/null || true)"

read_setting() {
  awk -F' = ' -v key="$1" '$0 ~ "^ +" key " = " { print $2; exit }' <<<"$SETTINGS"
}

PRODUCTS_DIR="$(read_setting BUILT_PRODUCTS_DIR)"
PRODUCT_NAME="$(read_setting FULL_PRODUCT_NAME)"
APP_PATH="$PRODUCTS_DIR/$PRODUCT_NAME"

if [[ ! -d "$APP_PATH" ]]; then
  log_error "The built app is not where the project says it is"
  print_field "Looked at:" "$APP_PATH"
  exit 1
fi

APP_BINARY="$APP_PATH/Contents/MacOS/$SCHEME"
PLIST="$APP_PATH/Contents/Info.plist"

read_plist() {
  /usr/libexec/PlistBuddy -c "Print $1" "$PLIST" 2>/dev/null || echo "?"
}

read_team() {
  codesign -dv --verbose=2 "$1" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }'
}

BUNDLE_ID="$(read_plist CFBundleIdentifier)"
SHORT_VERSION="$(read_plist CFBundleShortVersionString)"
BUILD_VERSION="$(read_plist CFBundleVersion)"
TEAM_ID="$(read_team "$APP_PATH")"
APP_SIZE="$(du -sh "$APP_PATH" 2>/dev/null | cut -f1 | tr -d ' ')"

echo ""
print_field "App:" "$APP_PATH"
print_field "Bundle ID:" "$BUNDLE_ID"
print_field "Version:" "$SHORT_VERSION ($BUILD_VERSION)"
print_field "Team:" "${TEAM_ID:-none}"
print_field "Size:" "${APP_SIZE:-?}"

# ----------------------------------------------------------------- test ----

if (( RUN_TESTS )); then
  echo ""
  log_info "Unit tests..."
  TEST_START=$SECONDS
  if xcodebuild "${XCODEBUILD_ARGS[@]}" -only-testing:SonorTests test 2>&1 | tee "$BUILD_LOG" | "${FORMATTER[@]}"; then
    log_success "Tests passed ${_CLI_GRAY}($((SECONDS - TEST_START))s)${_CLI_NC}"
  else
    log_error "Tests failed ${_CLI_GRAY}($((SECONDS - TEST_START))s)${_CLI_NC}"
    show_log_errors
    exit 1
  fi
fi

# ------------------------------------------------------------------ run ----

if (( ! START_APP )); then
  echo ""
  log_info "The app did not start. Drop ${_CLI_CYAN}--build-only${_CLI_NC} to start it."
  echo ""
  print_divider "$_CLI_PURPLE"
  echo ""
  exit 0
fi

echo ""

# Two copies of Sonor both claim the same hotkey, so any older copy has to go first.
RUNNING_PIDS="$(pgrep -f "/$SCHEME.app/Contents/MacOS/$SCHEME" || true)"
if [[ -n "$RUNNING_PIDS" ]]; then
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    OLD_PATH="$(ps -o comm= -p "$pid" 2>/dev/null || echo "unknown")"
    log_info "Quit an older copy ${_CLI_GRAY}(PID $pid)${_CLI_NC}"
    echo -e "      ${_CLI_GRAY}${OLD_PATH}${_CLI_NC}"
    kill "$pid" 2>/dev/null || true
  done <<<"$RUNNING_PIDS"
  sleep 1
fi

open "$APP_PATH"
sleep 2
NEW_PID="$(pgrep -f "$APP_BINARY" | head -1 || true)"

if [[ -n "$NEW_PID" ]]; then
  log_success "Sonor runs now ${_CLI_GRAY}(PID $NEW_PID)${_CLI_NC}"
else
  log_error "Sonor did not start"
  log_info "Start it by hand: ${_CLI_BLUE}open \"$APP_PATH\"${_CLI_NC}"
  exit 1
fi

echo ""
echo -e "  ${_CLI_GRAY}Sonor has no window. Look for its icon in the menu bar.${_CLI_NC}"

# ---------------------------------------------------------- permissions ----

INSTALLED_APP="/Applications/$SCHEME.app"
INSTALLED_TEAM=""
if [[ -d "$INSTALLED_APP" ]]; then
  INSTALLED_TEAM="$(read_team "$INSTALLED_APP")"
fi

echo ""
if [[ -n "$INSTALLED_TEAM" && "$INSTALLED_TEAM" != "$TEAM_ID" ]]; then
  log_warn "This build signs with a different team than ${_CLI_BLUE}$INSTALLED_APP${_CLI_NC}"
  echo -e "      ${_CLI_GRAY}this build: ${TEAM_ID:-none}    installed: ${INSTALLED_TEAM}${_CLI_NC}"
  echo -e "      ${_CLI_GRAY}macOS sees two apps, so the permissions do not carry over.${_CLI_NC}"
  echo ""
fi

log_info "If the hotkey does nothing, macOS did not grant Accessibility."
echo -e "      ${_CLI_GRAY}Add this app in System Settings, Privacy & Security, Accessibility:${_CLI_NC}"
echo -e "      ${_CLI_BLUE}${APP_PATH}${_CLI_NC}"
echo -e "      ${_CLI_GRAY}Open that pane with:${_CLI_NC} ${_CLI_CYAN}$0 --permissions${_CLI_NC}"

echo ""
print_divider "$_CLI_PURPLE"
echo ""
