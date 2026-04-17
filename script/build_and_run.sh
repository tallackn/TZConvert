#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.derivedData"
SCHEME="tzconvert"
DESTINATION="platform=macOS,arch=arm64"
EXECUTABLE="$DERIVED_DATA/Build/Products/Debug/tzconvert"

cd "$ROOT_DIR"

if pgrep -x "$SCHEME" >/dev/null 2>&1; then
  pkill -x "$SCHEME" || true
fi

xcodebuild \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  build

if [[ ! -x "$EXECUTABLE" ]]; then
  echo "Expected executable not found at: $EXECUTABLE" >&2
  exit 1
fi

if [[ "$#" -eq 0 ]]; then
  exec "$EXECUTABLE" --help
fi

exec "$EXECUTABLE" "$@"
