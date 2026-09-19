#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-Debug}"
VERSION="${2:-1.0.0}"
if [[ "$CONFIGURATION" != Debug && "$CONFIGURATION" != Release ]] ||
   [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ $# -gt 2 ]]; then
  echo "Usage: bash scripts/build.sh [Debug|Release] [X.Y.Z]" >&2
  exit 1
fi
for tool in xcodegen xcodebuild; do
  command -v "$tool" >/dev/null || { echo "Missing $tool; see docs/RELEASING.md" >&2; exit 1; }
done

SIGNING=(CODE_SIGNING_ALLOWED=NO)
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  : "${TEAM_ID:?Set TEAM_ID for signed builds}"
  SIGNING=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual
    "CODE_SIGN_IDENTITY=$SIGNING_IDENTITY" "DEVELOPMENT_TEAM=$TEAM_ID"
    OTHER_CODE_SIGN_FLAGS=--timestamp CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
fi

xcodegen generate --spec App/project.yml
xcodebuild -project App/NoteLume.xcodeproj -scheme NoteLume \
  -configuration "$CONFIGURATION" -derivedDataPath build/DerivedData \
  -destination 'generic/platform=macOS' \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  "MARKETING_VERSION=$VERSION" "CURRENT_PROJECT_VERSION=${BUILD_NUMBER:-$(git rev-list --count HEAD)}" \
  "${SIGNING[@]}" build

echo "App: $PWD/build/DerivedData/Build/Products/$CONFIGURATION/NoteLume.app"

# if debug mode, quit the running app and open the built app and build products directory
if [[ "$CONFIGURATION" == "Debug" ]]; then
  # quit running app
  if pgrep -x "NoteLume" >/dev/null 2>&1; then
    osascript -e 'tell application id "com.cybasoft.notelume" to quit' || true
    # termination flushes notes asynchronously; opening too early yields LaunchServices -600
    for _ in {1..50}; do
      pgrep -x "NoteLume" >/dev/null 2>&1 || break
      sleep 0.2
    done
  fi
  # open the built app
  open "$PWD/build/DerivedData/Build/Products/$CONFIGURATION/NoteLume.app"
fi