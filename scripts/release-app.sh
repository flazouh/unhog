#!/bin/zsh
set -euo pipefail

UNHOG_ROOT="${0:A:h:h}"
UNHOG_APP="$UNHOG_ROOT/dist/Unhog.app"

# Signing configuration is intentionally kept out of version control. Copy
# scripts/release.local.env.example to scripts/release.local.env and fill in
# your Developer ID identity, team, and notarytool keychain profile.
UNHOG_LOCAL_CONFIG="$UNHOG_ROOT/scripts/release.local.env"
if [[ -f "$UNHOG_LOCAL_CONFIG" ]]; then
  source "$UNHOG_LOCAL_CONFIG"
fi

UNHOG_IDENTITY="${UNHOG_SIGN_IDENTITY:-}"
UNHOG_EXPECTED_TEAM="${UNHOG_TEAM_ID:-}"
UNHOG_NOTARY_PROFILE="${UNHOG_NOTARY_PROFILE:-}"
UNHOG_NOTARY_KEY_ID="${UNHOG_NOTARY_KEY_ID:-}"
UNHOG_NOTARY_ISSUER_ID="${UNHOG_NOTARY_ISSUER_ID:-}"
UNHOG_NOTARY_KEY_PATH="${UNHOG_NOTARY_KEY_PATH:-}"
UNHOG_SHOULD_NOTARIZE=true

# There are two ways to authenticate to Apple's notary service. A developer Mac
# uses a keychain profile stored once by `notarytool store-credentials`. A hosted
# CI runner has no such keychain, so it passes App Store Connect API key material
# through the environment instead.
notary_auth=()
notary_method=""
if [[ -n "$UNHOG_NOTARY_KEY_ID$UNHOG_NOTARY_ISSUER_ID$UNHOG_NOTARY_KEY_PATH" ]]; then
  if [[ -z "$UNHOG_NOTARY_KEY_ID" || -z "$UNHOG_NOTARY_ISSUER_ID" || -z "$UNHOG_NOTARY_KEY_PATH" ]]; then
    print -u2 "Incomplete notary API key configuration."
    print -u2 "Set UNHOG_NOTARY_KEY_ID, UNHOG_NOTARY_ISSUER_ID, and UNHOG_NOTARY_KEY_PATH together."
    exit 1
  fi
  notary_auth=(
    --key "$UNHOG_NOTARY_KEY_PATH"
    --key-id "$UNHOG_NOTARY_KEY_ID"
    --issuer "$UNHOG_NOTARY_ISSUER_ID"
  )
  notary_method="API key $UNHOG_NOTARY_KEY_ID"
elif [[ -n "$UNHOG_NOTARY_PROFILE" ]]; then
  notary_auth=(--keychain-profile "$UNHOG_NOTARY_PROFILE")
  notary_method="keychain profile $UNHOG_NOTARY_PROFILE"
fi

usage() {
  cat <<'EOF'
Usage: ./scripts/release-app.sh [options]

Creates a Developer ID-signed disk image, submits it to Apple for
notarization, staples the result, and verifies the finished download.

Options:
  --skip-notarization    Build and sign only; intended for local verification
  --print-config         Print the locked signing configuration and exit
  --help                 Show this help
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --skip-notarization)
      UNHOG_SHOULD_NOTARIZE=false
      shift
      ;;
    --print-config)
      print "Signing identity: $UNHOG_IDENTITY"
      print "Expected team: $UNHOG_EXPECTED_TEAM"
      print "Notary auth: $notary_method"
      exit 0
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      print -u2 "Unknown option: $1"
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$UNHOG_IDENTITY" || -z "$UNHOG_EXPECTED_TEAM" || -z "$notary_method" ]]; then
  print -u2 "Missing signing configuration."
  print -u2 "Copy scripts/release.local.env.example to scripts/release.local.env"
  print -u2 "and set UNHOG_SIGN_IDENTITY, UNHOG_TEAM_ID, and UNHOG_NOTARY_PROFILE."
  exit 1
fi

if [[ -n "$UNHOG_NOTARY_KEY_PATH" && ! -f "$UNHOG_NOTARY_KEY_PATH" ]]; then
  print -u2 "Notary API key not found at $UNHOG_NOTARY_KEY_PATH"
  exit 1
fi

if [[ "$UNHOG_IDENTITY" != *"($UNHOG_EXPECTED_TEAM)"* ]]; then
  print -u2 "Signing identity does not match the configured team $UNHOG_EXPECTED_TEAM."
  exit 1
fi

# Quality gate: never sign or notarize code that fails lint, compile, or tests.
"$UNHOG_ROOT/scripts/verify.sh"
"$UNHOG_ROOT/scripts/test-release-config.sh"

if [[ "$UNHOG_SHOULD_NOTARIZE" == true ]]; then
  working_tree_status="$(git -C "$UNHOG_ROOT" status --porcelain)"
  if [[ -n "$working_tree_status" ]]; then
    print -u2 "Refusing to publish from a dirty Git working tree."
    print -u2 "Commit or safely set aside all changes, then run the release again."
    exit 1
  fi
  UNHOG_RELEASE_COMMIT="$(git -C "$UNHOG_ROOT" rev-parse HEAD)"
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$UNHOG_ROOT/Support/Info.plist")"
artifact_name="Unhog-$version.dmg"
UNHOG_PUBLIC_DMG="$UNHOG_ROOT/dist/$artifact_name"

if [[ "$UNHOG_SHOULD_NOTARIZE" == true ]] \
  && [[ -e "$UNHOG_PUBLIC_DMG" || -e "$UNHOG_PUBLIC_DMG.sha256" || -e "$UNHOG_PUBLIC_DMG.commit" ]]; then
  print -u2 "Release $artifact_name already exists."
  print -u2 "Bump the app version instead of overwriting a published artifact."
  exit 1
fi

available_identities="$(security find-identity -v -p codesigning)"
if [[ "$available_identities" != *"\"$UNHOG_IDENTITY\""* ]]; then
  print -u2 "Missing signing certificate:"
  print -u2 "  $UNHOG_IDENTITY"
  print -u2 "Install the certificate for team $UNHOG_EXPECTED_TEAM and try again."
  exit 1
fi

env UNHOG_SIGN_IDENTITY="$UNHOG_IDENTITY" "$UNHOG_ROOT/scripts/package-app.sh"

codesign --verify --deep --strict --verbose=2 "$UNHOG_APP"

signature_details="$(codesign --display --verbose=4 "$UNHOG_APP" 2>&1)"
signed_team="$(print -r -- "$signature_details" | sed -n 's/^TeamIdentifier=//p')"
if [[ "$signed_team" != "$UNHOG_EXPECTED_TEAM" ]]; then
  print -u2 "Wrong signing team: expected $UNHOG_EXPECTED_TEAM, found ${signed_team:-none}."
  exit 1
fi

if [[ "$signature_details" != *"Identifier=com.alex.unhog"* ]]; then
  print -u2 "Signed app has the wrong bundle identifier."
  exit 1
fi

if [[ "$signature_details" != *"flags="*"runtime"* ]]; then
  print -u2 "Signed app is missing Hardened Runtime."
  exit 1
fi

UNHOG_WORKDIR="$(mktemp -d "$UNHOG_ROOT/dist/.unhog-release.XXXXXX")"
UNHOG_STAGE="$UNHOG_WORKDIR/stage"
UNHOG_PENDING_DMG="$UNHOG_WORKDIR/$artifact_name"

cleanup() {
  rm -rf "$UNHOG_WORKDIR"
}
trap cleanup EXIT

install -d "$UNHOG_STAGE"
ditto "$UNHOG_APP" "$UNHOG_STAGE/Unhog.app"
ln -s /Applications "$UNHOG_STAGE/Applications"

hdiutil create \
  -volname "Unhog" \
  -srcfolder "$UNHOG_STAGE" \
  -ov \
  -format UDZO \
  "$UNHOG_PENDING_DMG"

codesign \
  --force \
  --timestamp \
  --sign "$UNHOG_IDENTITY" \
  "$UNHOG_PENDING_DMG"
codesign --verify --strict --verbose=2 "$UNHOG_PENDING_DMG"

if [[ "$UNHOG_SHOULD_NOTARIZE" == false ]]; then
  UNHOG_TEST_OUTPUT="$UNHOG_ROOT/dist/testing"
  UNHOG_TEST_DMG="$UNHOG_TEST_OUTPUT/Unhog-$version-NOT-NOTARIZED.dmg"
  install -d "$UNHOG_TEST_OUTPUT"
  if [[ -e "$UNHOG_TEST_DMG" ]]; then
    rm "$UNHOG_TEST_DMG"
  fi
  mv "$UNHOG_PENDING_DMG" "$UNHOG_TEST_DMG"

  print
  print "Built signed test release:"
  print "  $UNHOG_TEST_DMG"
  print "This clearly marked test file is not notarized. Do not publish it."
  exit 0
fi

xcrun notarytool submit \
  "$UNHOG_PENDING_DMG" \
  "${notary_auth[@]}" \
  --wait

xcrun stapler staple "$UNHOG_PENDING_DMG"
xcrun stapler validate "$UNHOG_PENDING_DMG"
spctl \
  --assess \
  --verbose=2 \
  --type open \
  --context context:primary-signature \
  "$UNHOG_PENDING_DMG"

current_commit="$(git -C "$UNHOG_ROOT" rev-parse HEAD)"
current_tree_status="$(git -C "$UNHOG_ROOT" status --porcelain)"
if [[ "$current_commit" != "$UNHOG_RELEASE_COMMIT" || -n "$current_tree_status" ]]; then
  print -u2 "Git changed while the release was being built."
  print -u2 "The approved DMG will not be promoted. Run the release again."
  exit 1
fi

checksum_hash="$(shasum -a 256 "$UNHOG_PENDING_DMG" | awk '{print $1}')"
print -r -- "$checksum_hash  $artifact_name" > "$UNHOG_PENDING_DMG.sha256"
print -r -- "$UNHOG_RELEASE_COMMIT" > "$UNHOG_PENDING_DMG.commit"
mv "$UNHOG_PENDING_DMG" "$UNHOG_PUBLIC_DMG"
mv "$UNHOG_PENDING_DMG.sha256" "$UNHOG_PUBLIC_DMG.sha256"
mv "$UNHOG_PENDING_DMG.commit" "$UNHOG_PUBLIC_DMG.commit"

print
print "Release is signed, notarized, stapled, and ready to publish:"
print "  $UNHOG_PUBLIC_DMG"
print "  $UNHOG_PUBLIC_DMG.sha256"
print "  $UNHOG_PUBLIC_DMG.commit"
