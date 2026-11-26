#!/usr/bin/env bash
# Builds a notarized, stapled build/HeyEQQ-<version>.dmg (universal: Apple Silicon + Intel) for distribution.
#
# One-time setup:
#   1. A "Developer ID Application" certificate in the login keychain (paid Apple Developer Program).
#   2. Notary credentials saved in the keychain:
#        xcrun notarytool store-credentials HeyEQQ-notary \
#          --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
#
# Usage:
#   scripts/release.sh
#   NOTARY_PROFILE=other-profile scripts/release.sh          # different keychain profile
#   DEVELOPER_ID="<sha1 or name>" scripts/release.sh          # pick a specific Developer ID identity
#   SKIP_NOTARIZE=1 scripts/release.sh                        # sign + DMG only (no upload)
#   AD_HOC=1 scripts/release.sh                               # ad-hoc signed DMG: no certificate, no name in
#                                                             # the signature, not notarized (current public builds)
#
# This does not replace scripts/build-app.sh for day-to-day work: the Developer ID signature differs
# from the Apple Development one, so running the release build grants it a separate TCC permission.
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-HeyEQQ-notary}"
APP=build/HeyEQQ.app
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
DMG="build/HeyEQQ-$VERSION.dmg"
VOLNAME="HeyEQQ $VERSION"

die() { echo "error: $*" >&2; exit 1; }

# --- Preflight ---------------------------------------------------------------------------------
if [[ "${AD_HOC:-0}" == 1 ]]; then
  DEVELOPER_ID="-"
  SKIP_NOTARIZE=1
fi
IDENTITY="${DEVELOPER_ID:-$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')}"
[[ -n "$IDENTITY" ]] || die "no \"Developer ID Application\" signing identity in the keychain.
       Create one at https://developer.apple.com/account/resources/certificates (needs a paid
       Apple Developer Program membership), or set DEVELOPER_ID."

if [[ "${SKIP_NOTARIZE:-0}" != 1 ]]; then
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "notarytool keychain profile \"$NOTARY_PROFILE\" not found or invalid. Run:
       xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id <team> --password <app-specific-password>"
fi

# --- Build + sign the app (universal, hardened runtime, secure timestamp) ---------------------------------
SIGN_IDENTITY="$IDENTITY" HARDENED_RUNTIME=1 UNIVERSAL=1 scripts/build-app.sh
codesign --verify --deep --strict --verbose=2 "$APP"

# --- DMG: app + /Applications shortcut ---------------------------------------------------------
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"
if [[ "$IDENTITY" != "-" ]]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi

# --- Notarize + staple -------------------------------------------------------------------------
if [[ "${SKIP_NOTARIZE:-0}" == 1 ]]; then
  echo "Skipped notarization: $DMG is signed but not notarized."
  exit 0
fi

echo "Submitting $DMG for notarization (this usually takes a few minutes)..."
SUBMIT_OUT="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
echo "$SUBMIT_OUT"
if ! grep -q "status: Accepted" <<<"$SUBMIT_OUT"; then
  SUB_ID="$(awk '/^ *id:/ {print $2; exit}' <<<"$SUBMIT_OUT")"
  [[ -n "$SUB_ID" ]] && xcrun notarytool log "$SUB_ID" --keychain-profile "$NOTARY_PROFILE" || true
  die "notarization was not accepted (log above)."
fi

xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo "Release ready: $DMG"
