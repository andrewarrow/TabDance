#!/bin/bash
set -euo pipefail
umask 077

app="dist/TabDance.app"
dmg="dist/TabDance-macos-arm64.dmg"

notarization_enabled=false
if [[ -n "${APPLE_NOTARY_KEY_P8:-}" ]]; then
  notarization_enabled=true
fi
if [[ "$notarization_enabled" == true ]] && \
    [[ -z "${APPLE_NOTARY_KEY_ID:-}" || -z "${APPLE_NOTARY_ISSUER_ID:-}" ]]; then
  echo "Notarization requires APPLE_NOTARY_KEY_P8, APPLE_NOTARY_KEY_ID, and APPLE_NOTARY_ISSUER_ID together." >&2
  exit 1
fi
if [[ "$notarization_enabled" == true && -z "${MACOS_SIGNING_IDENTITY:-}" ]]; then
  echo "Notarization requires a Developer ID signed app; configure the required macOS signing secrets first." >&2
  exit 1
fi

if [[ -n "${MACOS_SIGNING_IDENTITY:-}" ]]; then
  signing_args=(--force --options runtime --timestamp --sign "$MACOS_SIGNING_IDENTITY")
  if [[ -n "${MACOS_SIGNING_KEYCHAIN:-}" ]]; then
    signing_args+=(--keychain "$MACOS_SIGNING_KEYCHAIN")
  fi

  codesign "${signing_args[@]}" "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
  signing_status="Developer ID signed"
else
  codesign --verify --deep --strict "$app"
  signing_status="Ad-hoc signed"
fi

notarized=false
notary_key=""
app_zip=""
if [[ "$notarization_enabled" == true ]]; then
  notary_key="$RUNNER_TEMP/TabDance-AuthKey.p8"
  app_zip="$RUNNER_TEMP/TabDance-app-notarization.zip"
  trap 'rm -f "$notary_key" "$app_zip"' EXIT
  printf '%s' "$APPLE_NOTARY_KEY_P8" > "$notary_key"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$app_zip"
  xcrun notarytool submit "$app_zip" \
    --key "$notary_key" \
    --key-id "$APPLE_NOTARY_KEY_ID" \
    --issuer "$APPLE_NOTARY_ISSUER_ID" \
    --wait --timeout 30m
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=2 "$app"
  notarized=true
fi

staging="$RUNNER_TEMP/tabdance-dmg"
rm -rf "$staging" "$dmg"
mkdir -p "$staging"
ditto "$app" "$staging/TabDance.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname TabDance -srcfolder "$staging" \
  -ov -format UDZO "$dmg"

if [[ -n "${MACOS_SIGNING_IDENTITY:-}" ]]; then
  dmg_signing_args=(--force --timestamp --sign "$MACOS_SIGNING_IDENTITY")
  if [[ -n "${MACOS_SIGNING_KEYCHAIN:-}" ]]; then
    dmg_signing_args+=(--keychain "$MACOS_SIGNING_KEYCHAIN")
  fi
  codesign "${dmg_signing_args[@]}" "$dmg"
  codesign --verify --verbose=2 "$dmg"
fi

if [[ "$notarized" == true ]]; then
  xcrun notarytool submit "$dmg" \
    --key "$notary_key" \
    --key-id "$APPLE_NOTARY_KEY_ID" \
    --issuer "$APPLE_NOTARY_ISSUER_ID" \
    --wait --timeout 30m
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'signing=%s\nnotarized=%s\n' "$signing_status" "$notarized" >> "$GITHUB_OUTPUT"
fi
printf 'Packaged %s (%s; notarized=%s)\n' "$dmg" "$signing_status" "$notarized"
