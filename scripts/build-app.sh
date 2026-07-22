#!/bin/zsh
# Build Prompter.app from the SwiftPM package (no Xcode needed).
#
# Usage:
#   ./scripts/build-app.sh                 # build only (ad-hoc signed)
#   ./scripts/build-app.sh --install       # build + install to /Applications
#   ./scripts/build-app.sh --install --relaunch
#   ./scripts/build-app.sh --identity prompter-dev --install
#   ./scripts/build-app.sh --auth-lab        # DEBUG app with prompter-lab:// callback
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
AUTH_LAB=0
PROVISIONING_PROFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --install)  INSTALL=1; shift ;;
    --relaunch) RELAUNCH=1; shift ;;
    --version) VERSION="$2"; shift 2 ;;
    --build) BUILD_NUMBER="$2"; shift 2 ;;
    --update-repository) UPDATE_REPOSITORY="$2"; shift 2 ;;
    --provisioning-profile) PROVISIONING_PROFILE="$2"; shift 2 ;;
    --auth-lab) AUTH_LAB=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ $AUTH_LAB -eq 1 && "$IDENTITY" == Developer\ ID\ Application:* ]]; then
  echo "--auth-lab is development-only and cannot use a release signing identity" >&2
  exit 2
fi

if [[ "$IDENTITY" == Developer\ ID\ Application:* ]]; then
  if [[ -z "$PROVISIONING_PROFILE" || ! -f "$PROVISIONING_PROFILE" ]]; then
    echo "Developer ID releases require an Associated Domains provisioning profile." >&2
    exit 2
  fi
fi

BUILD_CONFIGURATION="release"
BUNDLE_IDENTIFIER="com.drew.prompter"
if [[ $AUTH_LAB -eq 1 ]]; then
  BUILD_CONFIGURATION="debug"
  BUNDLE_IDENTIFIER="com.drew.prompter.auth-lab"
fi

echo "==> swift build -c $BUILD_CONFIGURATION"
swift build -c "$BUILD_CONFIGURATION"

APP=build/Prompter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$BUILD_CONFIGURATION/Prompter" "$APP/Contents/MacOS/Prompter"
cp bundle/Info.plist "$APP/Contents/Info.plist"

if [[ -n "$PROVISIONING_PROFILE" ]]; then
  PROFILE_PLIST="$(mktemp)"
  openssl smime -verify -inform der -noverify -in "$PROVISIONING_PROFILE" -out "$PROFILE_PLIST"
  PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST")"
  PROFILE_TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$PROFILE_PLIST")"
  /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.associated-domains' "$PROFILE_PLIST" >/dev/null
  if [[ "$PROFILE_APP_ID" != "F3FXXB2HL6.com.drew.prompter" || "$PROFILE_TEAM_ID" != "F3FXXB2HL6" ]]; then
    echo "Provisioning profile does not authorize the production Prompter app." >&2
    rm -f "$PROFILE_PLIST"
    exit 2
  fi
  rm -f "$PROFILE_PLIST"
  cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
fi

if [[ $AUTH_LAB -eq 1 ]]; then
  # The custom callback exists only in a DEBUG binary and DEBUG bundle. Public
  # releases have no claimable custom URL scheme; they use verified HTTPS.
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_IDENTIFIER" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLName string com.drew.prompter.ambitious-lab" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string prompter-lab" "$APP/Contents/Info.plist"
fi

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
ENTITLEMENTS="bundle/Prompter.entitlements"
if [[ "$IDENTITY" == Developer\ ID\ Application:* ]]; then
  ENTITLEMENTS="bundle/Prompter.release.entitlements"
fi
SIGN_ARGS=(
  --force
  --sign "$IDENTITY"
  --identifier "$BUNDLE_IDENTIFIER"
  --entitlements "$ENTITLEMENTS"
)
if [[ "$IDENTITY" == Developer\ ID\ Application:* ]]; then
  # Developer ID distribution requires hardened runtime and a trusted timestamp.
  SIGN_ARGS+=(--options runtime --timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [[ "$IDENTITY" == Developer\ ID\ Application:* ]]; then
  SIGNED_ENTITLEMENTS="$(mktemp)"
  trap 'rm -f "$SIGNED_ENTITLEMENTS"' EXIT
  codesign -d --entitlements :- "$APP" > "$SIGNED_ENTITLEMENTS"
  if ! /usr/libexec/PlistBuddy \
    -c "Print :com.apple.developer.associated-domains" \
    "$SIGNED_ENTITLEMENTS" \
    | grep -Fqx "    webcredentials:www.ambitious.social"; then
    echo "Release signature is missing the Ambitious associated domain." >&2
    exit 1
  fi
  rm -f "$SIGNED_ENTITLEMENTS"
  trap - EXIT
fi

echo "Built $APP"

if [[ $INSTALL -eq 1 ]]; then
  INSTALLED_APP="/Applications/Ambitious Prompts.app"
  LEGACY_APP="/Applications/Prompter.app"
  pkill -x Prompter 2>/dev/null || true
  sleep 0.5
  rm -rf "$INSTALLED_APP"
  rm -rf "$LEGACY_APP"
  cp -R "$APP" "$INSTALLED_APP"
  echo "Installed $INSTALLED_APP"
  if [[ $RELAUNCH -eq 1 ]]; then
    open "$INSTALLED_APP"
    echo "Relaunched Ambitious Prompts"
  fi
fi
