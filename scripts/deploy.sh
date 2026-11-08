#!/usr/bin/env bash
#
# Build a Release copy of Wit's Copy and install it in place of the copy you use.
#
# Usage: INSTALL_PATH=/Applications/WitsCopy.app ./scripts/deploy.sh
#
# Before replacing, the current app, its preferences and its history folder are
# copied to lab/backups/<timestamp>/. Every rebuild changes the ad-hoc signature,
# so macOS may ask for the Accessibility permission (needed for paste) again.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGET="${INSTALL_PATH:-/Applications/WitsCopy.app}"
EXE="$TARGET/Contents/MacOS/WitsCopy"
DERIVED="$ROOT/lab/.derived-release"
STAGE="$(mktemp -d "$ROOT/lab/deploy-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
PREFS="$HOME/Library/Preferences/local.thewitness.WitsCopy.plist"
DATA="$HOME/Library/Application Support/Wit's Copy"

mkdir -p "$DERIVED"
touch "$DERIVED/.metadata_never_index"

echo "==> build"
nice -n 10 xcodebuild clean build \
  -project WitsCopy.xcodeproj -scheme WitsCopy -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" -jobs 2 \
  SWIFT_COMPILATION_MODE=wholemodule \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO ENABLE_HARDENED_RUNTIME=NO -quiet
ditto "$DERIVED/Build/Products/Release/WitsCopy.app" "$STAGE/WitsCopy.app"
python3 scripts/adhoc-sign.py "$STAGE/WitsCopy.app"

echo "==> quit running copy"
if pgrep -f "^$EXE" >/dev/null; then
  pkill -TERM -f "^$EXE"
  for _ in $(seq 1 80); do pgrep -f "^$EXE" >/dev/null || break; sleep 0.1; done
  if pgrep -f "^$EXE" >/dev/null; then
    echo "running copy did not quit; nothing replaced" >&2
    exit 1
  fi
fi

echo "==> back up"
BACKUP="$ROOT/lab/backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
if [ -d "$TARGET" ]; then ditto "$TARGET" "$BACKUP/WitsCopy.app"; fi
if [ -f "$PREFS" ]; then cp -p "$PREFS" "$BACKUP/"; fi
if [ -d "$DATA" ]; then ditto "$DATA" "$BACKUP/data"; fi

echo "==> install"
rm -rf "$TARGET"
ditto "$STAGE/WitsCopy.app" "$TARGET"
codesign --verify --deep --strict "$TARGET"

echo "==> launch"
open "$TARGET"
for _ in $(seq 1 80); do pgrep -f "^$EXE" >/dev/null && break; sleep 0.1; done
PID="$(pgrep -f "^$EXE" || true)"
[ -n "$PID" ] || { echo "installed copy did not start" >&2; exit 1; }
echo "==> $(plutil -extract CFBundleShortVersionString raw "$TARGET/Contents/Info.plist")" \
  "build $(plutil -extract CFBundleVersion raw "$TARGET/Contents/Info.plist")" \
  "pid $PID; backup in ${BACKUP#"$ROOT/"}"
