#!/usr/bin/env bash
# Syntax-check every Lua file in the addon with a Lua 5.1 compiler —
# the version WoW's client runs. Nothing here is WoW-specific, so a
# clean run proves the files parse, not that the addon behaves.
#
# Point LUAC at a compiler if it is not on PATH. Ubuntu ships one as
# `sudo apt install lua5.1`; without root, building upstream Lua 5.1.5
# with `make posix` takes about half a minute and needs only gcc.
set -uo pipefail

LUAC="${LUAC:-$(command -v luac5.1 || command -v luac || true)}"
if [[ -z "$LUAC" ]]; then
    echo "no Lua 5.1 compiler found; set LUAC=/path/to/luac" >&2
    exit 2
fi

cd "$(dirname "$0")/.."
fail=0
total=0
while IFS= read -r f; do
    total=$((total + 1))
    if ! out=$("$LUAC" -p "$f" 2>&1); then
        echo "FAIL $f: $out"
        fail=$((fail + 1))
    fi
done < <(find . -name '*.lua' -not -path './.git/*' | sort)

echo "$total files checked, $fail failed"
[[ $fail -eq 0 ]]
