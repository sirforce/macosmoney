#!/bin/sh
# Takes the documentation screenshots from the sample data. No real data is involved:
#
#   - the app is built with its own bundle id, so it has its own preferences;
#   - it runs with --demo, which keeps its data in its own folder (here a temporary one with a
#     neutral path, because a few screens show where the data lives);
#   - the app captures only its own window;
#   - every picture is then read back (OCR) and the run fails if your user name, full name or
#     home folder appears in any of them.
#
# Usage: tools/demo/screenshots.sh [scene,scene…]     (no argument: every scene)
# Output: docs/screenshots/*.png. The window comes to the front for about a minute and a half.
# See docs/demo-and-screenshots.md.
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/docs/screenshots"
DD="$ROOT/App/build/DemoDD"
WORK="/tmp/macmoney-demo"
APP="$DD/Build/Products/Release/MacMoney.app/Contents/MacOS/MacMoney"
ONLY="${1:-}"

echo "Building the demo variant…"
cd "$ROOT/App"
xcodegen generate >/dev/null
xcodebuild -project MacMoney.xcodeproj -scheme MacMoney -configuration Release -derivedDataPath "$DD" \
  PRODUCT_BUNDLE_IDENTIFIER=io.github.macmoney.MacMoney.demo build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
[ -x "$APP" ] || { echo "Build failed."; exit 1; }

run_tour() {   # $1 = data folder, $2 = output folder, $3… = arguments
  data="$1"; shots="$2"; shift 2
  MACMONEY_DEMO_DIR="$data" MACMONEY_TOUR_ONLY="$ONLY" "$APP" "$@" "--demo-tour=$shots" >/dev/null 2>&1 &
  pid=$!
  n=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 2; n=$((n + 2))
    [ "$n" -lt 300 ] || { kill "$pid"; echo "The tour did not finish."; exit 1; }
  done
  cat "$shots/tour.log"
}

rm -rf "$WORK"
mkdir -p "$WORK"
echo "Taking screenshots (the MacMoney window will come to the front)…"
run_tour "$WORK/data" "$WORK/shots" --demo-reset
[ -n "$ONLY" ] || run_tour "$WORK/empty" "$WORK/shots" --demo-empty

if grep -qv ": ok " "$WORK/shots/tour.log"; then echo "A screenshot failed; nothing was copied."; exit 1; fi

echo "Checking the pictures for personal details…"
swift "$ROOT/tools/demo/check-screenshots.swift" "$WORK/shots"

mkdir -p "$OUT"
for f in "$WORK"/shots/*.png; do
  # Half size is plenty for the web and keeps the repository small.
  sips -Z 1920 "$f" --out "$OUT/$(basename "$f")" >/dev/null
done
echo "Wrote $(ls "$OUT"/*.png | wc -l | tr -d ' ') screenshots to docs/screenshots/"
