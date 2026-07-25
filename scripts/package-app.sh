#!/bin/zsh
set -euo pipefail

UNHOG_ROOT="${0:A:h:h}"
UNHOG_BUILD="$UNHOG_ROOT/.build"
UNHOG_APP="$UNHOG_ROOT/dist/Unhog.app"
UNHOG_CONTENTS="$UNHOG_APP/Contents"
UNHOG_SIGN_IDENTITY="${UNHOG_SIGN_IDENTITY:--}"

env \
  CLANG_MODULE_CACHE_PATH="$UNHOG_BUILD/cache/clang" \
  SWIFTPM_MODULECACHE_OVERRIDE="$UNHOG_BUILD/cache/swiftpm" \
  XDG_CACHE_HOME="$UNHOG_BUILD/cache" \
  swift build \
    --package-path "$UNHOG_ROOT" \
    --product Unhog \
    --configuration release \
    --disable-sandbox

if [[ -e "$UNHOG_APP" ]]; then
  rm -rf "$UNHOG_APP"
fi

install -d "$UNHOG_CONTENTS/MacOS"
install -d "$UNHOG_CONTENTS/Resources"
install -m 755 "$UNHOG_BUILD/release/Unhog" "$UNHOG_CONTENTS/MacOS/Unhog"
install -m 644 "$UNHOG_ROOT/Support/Info.plist" "$UNHOG_CONTENTS/Info.plist"
install -m 644 "$UNHOG_ROOT/Support/Unhog.icns" "$UNHOG_CONTENTS/Resources/Unhog.icns"
cp -R \
  "$UNHOG_BUILD/release/Unhog_Unhog.bundle" \
  "$UNHOG_CONTENTS/Resources/Unhog_Unhog.bundle"

UNHOG_SPARKLE_SOURCE="$UNHOG_BUILD/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
UNHOG_SPARKLE="$UNHOG_CONTENTS/Frameworks/Sparkle.framework"

if [[ ! -d "$UNHOG_SPARKLE_SOURCE" ]]; then
  print -u2 "Sparkle framework missing at $UNHOG_SPARKLE_SOURCE"
  print -u2 "Run 'swift build' first so the artifact is resolved."
  exit 1
fi

install -d "$UNHOG_CONTENTS/Frameworks"
cp -R "$UNHOG_SPARKLE_SOURCE" "$UNHOG_SPARKLE"

# Signed inner-out, never with --deep: Sparkle's Downloader service carries
# entitlements the sibling binaries must not inherit, and --deep would overwrite
# the nested signatures with the outer one's terms.
sign_target() {
  local target="$1"
  shift
  if [[ "$UNHOG_SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$@" "$target"
  else
    codesign \
      --force \
      --options runtime \
      --timestamp \
      --sign "$UNHOG_SIGN_IDENTITY" \
      "$@" \
      "$target"
  fi
}

sign_target "$UNHOG_SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign_target "$UNHOG_SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
  --preserve-metadata=entitlements
sign_target "$UNHOG_SPARKLE/Versions/B/Autoupdate"
sign_target "$UNHOG_SPARKLE/Versions/B/Updater.app"
sign_target "$UNHOG_SPARKLE"
sign_target "$UNHOG_APP"

print "Built $UNHOG_APP"
