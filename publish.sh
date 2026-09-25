#!/bin/bash
# Publishes the disk image, the updater zip, and appcast.json on a GitHub
# release. The app reads the appcast from the latest release, and the zip it
# names has to be on that same host.
#
#   ./publish.sh
#
# ./build.sh release ship makes the three files first. The tag is v<version>
# from VERSION. Re-releasing the same version means deleting that release
# first — a build number can move, a tag cannot.
set -euo pipefail

cd "$(dirname "$0")"
VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"
REPO="${SEARCH_RELEASE_REPO:-noahveenstra/Search}"
FILES=(build/SearchByNoah.dmg build/SearchByNoah.zip build/appcast.json)

for FILE in "${FILES[@]}"; do
  [ -f "$FILE" ] || { echo "$FILE is missing — ./build.sh release ship makes it" >&2; exit 1; }
done

NOTES="Search by Noah $VERSION"
if [ -f NOTES.md ]; then
  FIRST="$(awk 'NF { printf "%s%s", (n++ ? " " : ""), $0; next } n { exit }' NOTES.md)"
  [ -n "$FIRST" ] && NOTES="$FIRST"
fi

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "release $TAG already exists on $REPO — delete it before publishing this version again" >&2
  exit 1
fi

gh release create "$TAG" "${FILES[@]}" \
  --repo "$REPO" \
  --title "Search by Noah $VERSION" \
  --notes "$NOTES"

echo "released: https://github.com/$REPO/releases/tag/$TAG"
