#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
plugin="$root/plugins/jjwxc.koplugin"

if command -v luac5.1 >/dev/null 2>&1; then
    compiler=luac5.1
elif command -v luac >/dev/null 2>&1; then
    compiler=luac
else
    echo "Lua compiler not found. Install Lua 5.1 to run syntax checks." >&2
    exit 1
fi

find "$plugin" -type f -name '*.lua' -exec "$compiler" -p '{}' \;

if grep -R -n -E "(/Users/|/home/|/mnt/data|Bearer[[:space:]]+[A-Za-z0-9]|token[[:space:]]*=[[:space:]]*['\"]?[A-Za-z0-9]{16})" "$plugin"; then
    echo "Potential local path or credential found; inspect before publishing." >&2
    exit 1
fi

echo "Lua syntax and basic secret checks passed."
