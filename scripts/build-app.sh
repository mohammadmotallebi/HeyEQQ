#!/usr/bin/env bash
# Builds build/HeyEQQ.app (release) and signs it.
# Signing with a stable identity keeps the System Audio Recording permission across rebuilds;
# ad-hoc signing (no identity found) makes macOS ask again after every rebuild.
#   SIGN_IDENTITY="<sha1 or name>" scripts/build-app.sh   # override identity
#   scripts/build-app.sh --open                           # build, then (re)launch
#   scripts/build-app.sh --install                        # build, copy to /Applications, launch from there
#   HARDENED_RUNTIME=1 SIGN_IDENTITY=... scripts/build-app.sh  # hardened runtime + timestamp (used by release.sh)
#   UNIVERSAL=1 scripts/build-app.sh                      # Apple Silicon + Intel binary (used by release.sh)
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH_FLAGS=()
[[ "${UNIVERSAL:-0}" == 1 ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build -c release --product HeyEQQ ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/HeyEQQ"

APP=build/HeyEQQ.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HeyEQQ"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns Support/MenuBarIcon.png Support/MenuBarIcon@2x.png "$APP/Contents/Resources/"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
if [[ -n "$IDENTITY" ]]; then
  if [[ "${HARDENED_RUNTIME:-0}" == 1 ]]; then
    codesign --force --sign "$IDENTITY" --options runtime --timestamp \
      --entitlements Support/HeyEQQ.entitlements "$APP"
  else
    codesign --force --sign "$IDENTITY" "$APP"
  fi
  echo "Signed with $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "Ad-hoc signed (permission will be re-requested after each rebuild)"
fi

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/HeyEQQ"))"

case "${1:-}" in
  --open)
    pkill -x HeyEQQ 2>/dev/null && sleep 0.5 || true
    open "$APP"
    ;;
  --install)
    pkill -x HeyEQQ 2>/dev/null && sleep 0.5 || true
    rm -rf /Applications/HeyEQQ.app
    cp -R "$APP" /Applications/HeyEQQ.app
    echo "Installed /Applications/HeyEQQ.app"
    open /Applications/HeyEQQ.app
    ;;
esac
