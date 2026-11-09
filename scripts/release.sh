#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:-}"
if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ $# -gt 2 ]] ||
   [[ -n "${2:-}" && "${2:-}" != --publish ]]; then
  echo "Usage: bash scripts/release.sh vX.Y.Z [--publish]" >&2
  exit 1
fi
VERSION="${TAG#v}"
TEAM_ID="${TEAM_ID:-UA5R4WVYA6}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notelume-notary}"
OUT="build/release/$TAG"
APP="$OUT/NoteLume.app"
ZIP="$OUT/NoteLume-$VERSION.zip"
DMG="$OUT/NoteLume-$VERSION.dmg"
SOURCE_COMMIT="$(git rev-parse HEAD)"

notarize() {
  local artifact="$1"
  local result="$2"
  xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json > "$result"
  if [[ "$(plutil -extract status raw -o - "$result")" != Accepted ]]; then
    echo "Notarization was not accepted; inspect $result and use notarytool log for details." >&2
    exit 1
  fi
}

for tool in xcodegen xcodebuild swift security codesign xcrun ditto hdiutil plutil; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes before releasing." >&2; exit 1; }
[[ ! -e "$OUT" ]] || { echo "$OUT already exists; move it aside before rebuilding." >&2; exit 1; }
SIGNING_IDENTITY="${SIGNING_IDENTITY:-$(security find-identity -v -p codesigning |
  sed -n "s/.*\"\(Developer ID Application:.*($TEAM_ID)\)\".*/\1/p" | head -1)}"
[[ -n "$SIGNING_IDENTITY" ]] || { echo "No Developer ID Application certificate for $TEAM_ID in Keychain." >&2; exit 1; }
security find-identity -v -p codesigning | grep -F "\"$SIGNING_IDENTITY\"" >/dev/null ||
  { echo "Signing identity not available: $SIGNING_IDENTITY" >&2; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null

if [[ "${2:-}" == --publish ]]; then
  command -v gh >/dev/null || { echo "Install GitHub CLI: brew install gh" >&2; exit 1; }
  gh auth status
  REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
  [[ "$(gh repo view "$REPO" --json visibility --jq .visibility)" == PUBLIC ]] ||
    { echo "Make $REPO public before publishing an open-source release." >&2; exit 1; }
  BRANCH="$(gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name)"
  [[ "$(git branch --show-current)" == "$BRANCH" ]] ||
    { echo "Publish from the default branch: $BRANCH" >&2; exit 1; }
  if git show-ref --verify --quiet "refs/tags/$TAG" ||
     [[ -n "$(git ls-remote --exit-code --tags origin "refs/tags/$TAG" || true)" ]]; then
    echo "Tag $TAG already exists; choose a new version." >&2
    exit 1
  fi
fi

swift test --package-path Core
TEAM_ID="$TEAM_ID" SIGNING_IDENTITY="$SIGNING_IDENTITY" bash scripts/build.sh Release "$VERSION"
mkdir -p "$OUT"
ditto build/DerivedData/Build/Products/Release/NoteLume.app "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
notarize "$OUT/notarize.zip" "$OUT/app-notarization.json"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
rm "$OUT/notarize.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

mkdir -p "$OUT/dmg"
ditto "$APP" "$OUT/dmg/NoteLume.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname "NoteLume $VERSION" -srcfolder "$OUT/dmg" -format UDZO "$DMG"
codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG"
notarize "$DMG" "$OUT/dmg-notarization.json"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
(cd "$OUT" && shasum -a 256 "NoteLume-$VERSION.dmg" "NoteLume-$VERSION.zip" > SHA256SUMS.txt)
echo "Release artifacts: $PWD/$OUT"

if [[ "${2:-}" == --publish ]]; then
  [[ -z "$(git status --porcelain)" ]] || { echo "Working tree changed during the build; refusing to publish." >&2; exit 1; }
  [[ "$(git rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || { echo "Source commit changed during the build; refusing to publish." >&2; exit 1; }
  git tag -a "$TAG" -m "NoteLume $VERSION"
  git push --atomic origin "HEAD:refs/heads/$BRANCH" "refs/tags/$TAG"
  gh release create "$TAG" "$DMG" "$ZIP" "$OUT/SHA256SUMS.txt" \
    --repo "$REPO" --title "NoteLume $VERSION" --generate-notes --verify-tag
fi