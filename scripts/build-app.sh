#!/bin/zsh
# Build Prompter.app from the SwiftPM package (no Xcode needed).
#
# Usage:
#   ./scripts/build-app.sh                 # build only (ad-hoc signed)
#   ./scripts/build-app.sh --install       # build + install to /Applications
#   ./scripts/build-app.sh --install --relaunch
#   ./scripts/build-app.sh --identity prompter-dev --install
#   ./scripts/build-app.sh --version 1.0.42 --build 42 --update-repository owner/repo
#
# NOTE on permissions: with ad-hoc signing ("-"), macOS treats every rebuilt
# binary as a new app, so Microphone/Accessibility grants reset after each
# code change. Public releases must use the same Developer ID Application
# identity every time. Local builds can use a stable self-signed identity.

set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="-"
INSTALL=0
RELAUNCH=0
VERSION=""
BUILD_NUMBER=""
UPDATE_REPOSITORY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --install)  INSTALL=1; shift ;;
    --relaunch) RELAUNCH=1; shift ;;
    --version) VERSION="$2"; shift 2 ;;
    --build) BUILD_NUMBER="$2"; shift 2 ;;
    --update-repository) UPDATE_REPOSITORY="$2"; shift 2 ;;
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

if [[ -n "$VERSION" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "$BUILD_NUMBER" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
if [[ -n "$UPDATE_REPOSITORY" ]]; then
  /usr/libexec/PlistBuddy -c "Set :PrompterUpdateRepository $UPDATE_REPOSITORY" "$APP/Contents/Info.plist"
fi

if [[ ! -f bundle/AppIcon.icns ]]; then
  echo "==> rendering AppIcon.icns"
  swift scripts/make-icon.swift bundle
fi
cp bundle/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> codesign (identity: $IDENTITY)"
SIGN_ARGS=(
  --force
  --sign "$IDENTITY"
  --identifier com.drew.prompter
  --entitlements bundle/Prompter.entitlements
)
if [[ "$IDENTITY" == Developer\ ID\ Application:* ]]; then
  # Developer ID distribution requires hardened runtime and a trusted timestamp.
  SIGN_ARGS+=(--options runtime --timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "Built $APP"

if [[ $INSTALL -eq 1 ]]; then
  pkill -x Prompter 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/Prompter.app
  cp -R "$APP" /Applications/Prompter.app
  echo "Installed /Applications/Prompter.app"
  if [[ $RELAUNCH -eq 1 ]]; then
    open /Applications/Prompter.app
    echo "Relaunched Prompter"
  fi
fi
