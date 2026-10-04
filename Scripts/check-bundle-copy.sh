#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
binary="${1:-.build/release/uc-watchdog}"
directory="$(mktemp -d "$PWD/.build/bundle-copy.XXXXXX")"
trap 'rm -rf "$directory"' EXIT
source_app="$directory/Source.app"
copied_app="$directory/Copied.app"
"$binary" bundle --output "$source_app"
# Exercise preservation of a signature different from the local bundle builder's
# signature, as well as resources and extended attributes used in distribution.
printf 'Distribution resource\n' >"$source_app/Contents/Resources/distribution.txt"
/usr/bin/codesign --remove-signature "$source_app"
/usr/bin/codesign --sign - --options runtime "$source_app"
/usr/bin/xattr -w local.uc-watchdog.copy-test retained "$source_app"
"$source_app/Contents/MacOS/uc-watchdog" bundle --output "$copied_app"
/usr/bin/codesign --verify --strict "$copied_app"
/usr/bin/cmp "$source_app/Contents/MacOS/uc-watchdog" "$copied_app/Contents/MacOS/uc-watchdog"
/usr/bin/cmp "$source_app/Contents/_CodeSignature/CodeResources" "$copied_app/Contents/_CodeSignature/CodeResources"
/usr/bin/cmp "$source_app/Contents/Info.plist" "$copied_app/Contents/Info.plist"
/usr/bin/cmp "$source_app/Contents/Resources/distribution.txt" "$copied_app/Contents/Resources/distribution.txt"
[[ "$(/usr/bin/xattr -p local.uc-watchdog.copy-test "$copied_app")" == retained ]]
# Corrupted signed resources must be rejected before staging an installation.
printf 'Tampered\n' >>"$source_app/Contents/Resources/distribution.txt"
if "$source_app/Contents/MacOS/uc-watchdog" bundle --output "$directory/Invalid.app"; then
    echo 'Invalid source signature was accepted.' >&2
    exit 1
fi
[[ ! -e "$directory/Invalid.app" ]]
echo 'Bundle copy checks passed; no installation or service signals performed.'
