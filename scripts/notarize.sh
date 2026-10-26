#!/bin/bash
# Submits a file to Apple's notary service, waits, and staples the ticket.
#   scripts/notarize.sh <file.zip|file.dmg> [path/to/Cra.app to staple]
# Credentials, either:
#   NOTARY_KEYCHAIN_PROFILE   a profile stored with `xcrun notarytool store-credentials`
# or
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD   (an app-specific password)
set -euo pipefail
FILE="$1"
STAPLE_APP="${2:-}"
if [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
  AUTH=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
  AUTH=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
else
  # Only called for Developer ID builds, and Gatekeeper rejects those unnotarized.
  echo "No notarization credentials in the environment. Set NOTARY_KEYCHAIN_PROFILE or APPLE_ID, APPLE_TEAM_ID and APPLE_APP_PASSWORD." >&2
  exit 1
fi
echo "Notarizing $(basename "$FILE")…"
xcrun notarytool submit "$FILE" "${AUTH[@]}" --wait --timeout 30m
case "$FILE" in
  *.dmg) xcrun stapler staple "$FILE" ;;
esac
if [ -n "$STAPLE_APP" ]; then
  xcrun stapler staple "$STAPLE_APP"
fi
echo "Notarized."
