#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$root/plugins/jjwxc.koplugin/_meta.lua")
test -n "$version"
mkdir -p "$root/dist"
archive="$root/dist/jjwxc-koreader-v${version}.zip"

cd "$root/plugins"
zip -qr "$archive" jjwxc.koplugin -x '*/.DS_Store'
unzip -t "$archive"
echo "Created $archive"
