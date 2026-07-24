#!/bin/zsh
set -euo pipefail

UNHOG_ROOT="${0:A:h:h}"
UNHOG_RELEASE_SCRIPT="$UNHOG_ROOT/scripts/release-app.sh"
UNHOG_PUBLISH_SCRIPT="$UNHOG_ROOT/scripts/publish-github-release.sh"

config="$("$UNHOG_RELEASE_SCRIPT" --print-config)"
publish_config="$("$UNHOG_PUBLISH_SCRIPT" --print-config)"

identity="$(print -r -- "$config" | sed -n 's/^Signing identity: //p')"
team="$(print -r -- "$config" | sed -n 's/^Expected team: //p')"
notary="$(print -r -- "$config" | sed -n 's/^Notary auth: //p')"

if [[ -z "$identity" || -z "$team" || -z "$notary" ]]; then
  print -u2 "Release signing configuration is incomplete."
  print -u2 "Create scripts/release.local.env from scripts/release.local.env.example."
  exit 1
fi

if [[ "$identity" != "Developer ID Application:"* ]]; then
  print -u2 "Release identity is not a Developer ID Application certificate."
  exit 1
fi

if [[ "$identity" != *"($team)"* ]]; then
  print -u2 "Signing identity does not match the configured team $team."
  exit 1
fi

if [[ "$publish_config" != *"GitHub repository: flazouh/unhog"* ]]; then
  print -u2 "Release downloads are not locked to the public Unhog repository."
  exit 1
fi

print "Release configuration contract passed."
