#!/bin/bash
# This fork does not publish a Homebrew cask. Updates ship as GitHub releases
# via ./publish.sh, which is what the app's updater reads. The script below
# is Office Commun's tap publisher and would push to their repository.
echo "this fork publishes with ./publish.sh, not a Homebrew tap" >&2
exit 1
set -euo pipefail

cd "$(dirname "$0")"
VERSION="$(tr -d '[:space:]' < VERSION)"
URL="https://github.com/driceroland/Search/releases/download/v$VERSION/Search.dmg"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL -o "$WORK/Search.dmg" "$URL" \
  || { echo "no Search.dmg on the v$VERSION release yet — publish the release first" >&2; exit 1; }
SHA="$(shasum -a 256 "$WORK/Search.dmg" | cut -d' ' -f1)"

git clone -q https://github.com/driceroland/homebrew-tap.git "$WORK/tap"
CASK="$WORK/tap/Casks/search.rb"
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
if git -C "$WORK/tap" diff --quiet; then
  echo "the tap already has Search $VERSION"
  exit 0
fi
git -C "$WORK/tap" commit -qam "Search $VERSION"
git -C "$WORK/tap" push -q
echo "tap: Search $VERSION, sha256 $SHA"
