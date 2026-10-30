#!/bin/bash
# Builds a release of MacMoney: archive → sign with Developer ID (hardened runtime) → notarize →
# staple → DMG → install into /Applications.
#
# Usage: tools/release/release.sh [--skip-tests] [--no-notarize] [--no-dmg] [--no-install]
#
# Configuration comes from tools/release/release.env (git-ignored; copy release.env.example).
set -euo pipefail
cd "$(dirname "$0")/../.."

step() { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[ -f tools/release/release.env ] && source tools/release/release.env
: "${TEAM_ID:?Set TEAM_ID in tools/release/release.env (see release.env.example)}"
SIGN_IDENTITY=${SIGN_IDENTITY:-"Developer ID Application"}
NOTARY_PROFILE=${NOTARY_PROFILE:-MacMoney-notary}

TESTS=1 NOTARIZE=1 INSTALL=1 DMG_STEP=1
for arg in "$@"; do
  case $arg in
    --skip-tests) TESTS=0 ;;
    --no-notarize) NOTARIZE=0 ;;
    --no-install) INSTALL=0 ;;
    --no-dmg) DMG_STEP=0 ;;
    *) fail "Unknown option $arg" ;;
  esac
done

VERSION=$(sed -nE 's/^ *MARKETING_VERSION: *"?([^"]+)"?/\1/p' App/project.yml | head -1)
BUILD=$(git rev-list --count HEAD)
OUT="App/build/release/MacMoney-$VERSION-$BUILD"
APP="$OUT/MacMoney.app"
DMG="$OUT/MacMoney-$VERSION.dmg"
echo "MacMoney $VERSION (build $BUILD) — signing as \"$SIGN_IDENTITY\" (team $TEAM_ID)"
[ -z "$(git status --porcelain)" ] || echo "⚠️  The working tree has uncommitted changes; they will be included."

security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY.*($TEAM_ID)" \
  || fail "No \"$SIGN_IDENTITY\" certificate for team $TEAM_ID in your keychain."
if [ $NOTARIZE = 1 ] && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  fail "No notarization credentials saved as \"$NOTARY_PROFILE\". Run once:
    xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <your Apple ID> --team-id $TEAM_ID
  (it asks for an app-specific password from account.apple.com), or use an App Store Connect API key:
    xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --key AuthKey_XXXX.p8 --key-id <id> --issuer <issuer-uuid>
  Or run with --no-notarize for a signed, un-notarized build."
fi

rm -rf "$OUT"; mkdir -p "$OUT"

step "Generating project"
(cd App && xcodegen generate >/dev/null)

if [ $TESTS = 1 ]; then
  step "Running tests"
  (cd App && xcodebuild -project MacMoney.xcodeproj -scheme MacMoney -derivedDataPath build/DD test -quiet) \
    || fail "Tests failed — not releasing."
fi

step "Archiving (Release, hardened runtime, Developer ID)"
xcodebuild -project App/MacMoney.xcodeproj -scheme MacMoney -configuration Release \
  -archivePath "$OUT/MacMoney.xcarchive" -derivedDataPath App/build/DD-release archive -quiet \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" CURRENT_PROJECT_VERSION="$BUILD"
ditto "$OUT/MacMoney.xcarchive/Products/Applications/MacMoney.app" "$APP"

step "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority=Developer ID|flags=.*runtime|TeamIdentifier" || fail "Unexpected signature"

notarize() {   # file to submit
  step "Notarizing $(basename "$1") (usually 1–5 minutes)"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m | tee "$OUT/notary.log"
  grep -q "status: Accepted" "$OUT/notary.log" || fail "Notarization was not accepted. Details:
    xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"
}

if [ $NOTARIZE = 1 ]; then
  ditto -c -k --keepParent "$APP" "$OUT/MacMoney.zip"
  notarize "$OUT/MacMoney.zip"
  xcrun stapler staple "$APP"
fi

if [ $DMG_STEP = 1 ]; then
step "Building disk image"
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/MacMoney.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "MacMoney $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
rm -rf "$STAGE"
# A mounted copy (opened in Finder, say) makes notarytool stall at "initiating connection".
hdiutil info | awk -v img="$DMG" '$1=="image-path" && $3==img {f=1; next} f && /^\/dev\/disk[0-9]+[ \t]/ {print $1; exit} /^====/ {f=0}' |
  while read -r dev; do hdiutil detach "$dev" -quiet || hdiutil detach "$dev" -force -quiet; done
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
if [ $NOTARIZE = 1 ]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi
fi

if [ $INSTALL = 1 ]; then
  step "Installing to /Applications"
  if pgrep -xq MacMoney; then
    echo "Quitting MacMoney (it takes its automatic backup on the way out)…"
    osascript -e 'tell application id "io.github.macmoney.MacMoney" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do pgrep -xq MacMoney || break; sleep 0.5; done
    pgrep -xq MacMoney && fail "MacMoney is still running. Quit it (⌘Q) and run this again."
  fi
  rm -rf /Applications/MacMoney.app
  ditto "$APP" /Applications/MacMoney.app
  spctl --assess --type execute -vv /Applications/MacMoney.app 2>&1 | sed 's/^/  /'
  open /Applications/MacMoney.app
fi

printf '\n\033[1;32m✓ MacMoney %s (build %s)\033[0m\n  App: %s\n' "$VERSION" "$BUILD" "$APP"
if [ $DMG_STEP = 1 ]; then printf "  DMG: %s\n" "$DMG"; fi
