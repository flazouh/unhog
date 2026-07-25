#!/bin/zsh
set -euo pipefail

# Publishes the Sparkle update feed for the version currently in Info.plist.
#
# Sparkle polls one fixed URL, but a GitHub release asset lives under a URL that
# moves with every tag. The feed is therefore regenerated per release with that
# tag's download prefix and replaces the previous feed wholesale: an accumulated
# feed would keep older entries whose prefix pointed at their own tag, which
# generate_appcast cannot express in a single run.

UNHOG_ROOT="${0:A:h:h}"
UNHOG_REPOSITORY="flazouh/unhog"
UNHOG_PAGES_BRANCH="gh-pages"
UNHOG_SPARKLE_BIN="$UNHOG_ROOT/.build/artifacts/sparkle/Sparkle/bin"

dry_run=false
if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=true
  shift
fi

if (( $# > 0 )); then
  print -u2 "Usage: ./scripts/publish-appcast.sh [--dry-run]"
  exit 2
fi

if [[ -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  print -u2 "SPARKLE_PRIVATE_KEY is not set."
  print -u2 "Without it the feed would be unsigned and every client would refuse it."
  exit 1
fi

if [[ ! -x "$UNHOG_SPARKLE_BIN/generate_appcast" ]]; then
  print -u2 "Sparkle tools missing at $UNHOG_SPARKLE_BIN"
  print -u2 "Run 'swift build' first so the artifact is resolved."
  exit 1
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$UNHOG_ROOT/Support/Info.plist")"
tag="v$version"
dmg="$UNHOG_ROOT/dist/Unhog-$version.dmg"

if [[ ! -f "$dmg" ]]; then
  print -u2 "Missing $dmg. Run ./scripts/release-app.sh first."
  exit 1
fi

workdir="$(mktemp -d)"
cleanup() {
  git -C "$UNHOG_ROOT" worktree remove --force "$workdir/pages" 2>/dev/null || true
  rm -rf "$workdir"
}
trap cleanup EXIT

# Only the new disk image is staged, so the generated feed describes exactly one
# version and every enclosure URL belongs to the tag being released.
install -d "$workdir/staging"
cp "$dmg" "$workdir/staging/"

print "$SPARKLE_PRIVATE_KEY" | "$UNHOG_SPARKLE_BIN/generate_appcast" \
  --ed-key-file - \
  --download-url-prefix "https://github.com/$UNHOG_REPOSITORY/releases/download/$tag/" \
  --link "https://github.com/$UNHOG_REPOSITORY" \
  --full-release-notes-url "https://github.com/$UNHOG_REPOSITORY/releases" \
  "$workdir/staging"

feed="$workdir/staging/appcast.xml"

# An unsigned enclosure is the one failure that looks like success: the feed
# publishes, and then every client rejects the update it advertises.
if ! rg -q 'sparkle:edSignature="[^"]+"' "$feed"; then
  print -u2 "Generated feed carries no EdDSA signature. Refusing to publish it."
  print -u2 "Check that Info.plist still has SUPublicEDKey and that the key matches."
  exit 1
fi

if ! rg -q "releases/download/$tag/Unhog-$version.dmg" "$feed"; then
  print -u2 "Generated feed does not point at $tag. Refusing to publish it."
  exit 1
fi

print "Generated feed for $version:"
cat "$feed"

if [[ "$dry_run" == true ]]; then
  print "Dry run: not pushing to $UNHOG_PAGES_BRANCH."
  exit 0
fi

git -C "$UNHOG_ROOT" fetch --depth 1 origin "$UNHOG_PAGES_BRANCH"
git -C "$UNHOG_ROOT" worktree add --detach "$workdir/pages" FETCH_HEAD > /dev/null
cp "$feed" "$workdir/pages/appcast.xml"

if git -C "$workdir/pages" diff --quiet -- appcast.xml; then
  print "Feed already matches what is published; nothing to push."
  exit 0
fi

git -C "$workdir/pages" add appcast.xml
git -C "$workdir/pages" \
  -c user.name="github-actions[bot]" \
  -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  commit -q -m "Offer Unhog $version to Sparkle clients"
git -C "$workdir/pages" push origin "HEAD:$UNHOG_PAGES_BRANCH"

print "Published the update feed for $version."
