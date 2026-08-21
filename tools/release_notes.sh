#!/usr/bin/env bash
# Print the CHANGELOG section for one version, for use as release notes.
#
# Usage: tools/release_notes.sh 0.38.1
set -euo pipefail

cd "$(dirname "$0")/.."
version="${1:?usage: release_notes.sh <version>}"

# From the heading for this version up to the next version heading.
notes=$(awk -v v="$version" '
    $0 ~ "^## " v "( |$|—)" { found = 1; next }
    found && /^## / { exit }
    found { print }
' CHANGELOG.md)

if [[ -z ${notes//[[:space:]]/} ]]; then
    echo "no CHANGELOG section found for $version" >&2
    exit 1
fi

printf '%s\n' "$notes"
