#!/bin/zsh
# Build Prompter.app from the SwiftPM package (no Xcode needed).
#
# Usage:
#   ./scripts/build-app.sh                 # build only (ad-hoc signed)
#   ./scripts/build-app.sh --install       # build + install to /Applications
#   ./scripts/build-app.sh --identity prompter-dev --install
#
# NOTE on permissions: with ad-hoc signing ("-"), macOS treats every rebuilt
# binary as a new app, so Microphone/Accessibility grants reset after each
# code change. For a stable identity, create a self-signed code-signing
# certificate once (Keychain Access → Certificate Assistant → Create a
# Certificate → name "prompter-dev", type "Code Signing") and pass
# --identity prompter-dev.

set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="-"
INSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --install)  INSTALL=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

echo "==> swift build -c release"
swift build -c release

APP=build/Prompter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Prompter "$APP/Contents/MacOS/Prompter"
cp bundle/Info.plist "$APP/Contents/Info.plist"

echo "==> codesign (identity: $IDENTITY)"
codesign --force --sign "$IDENTITY" --identifier com.drew.prompter "$APP"
codesign --verify --strict "$APP"

echo "Built $APP"

if [[ $INSTALL -eq 1 ]]; then
  pkill -x Prompter 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/Prompter.app
  cp -R "$APP" /Applications/Prompter.app
  echo "Installed /Applications/Prompter.app"
fi
