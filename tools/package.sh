#!/usr/bin/env bash
# Build the installable addon zip.
#
# Produces dist/ClassCodex-<version>.zip containing exactly one top-level
# folder, ClassCodex/, so it extracts straight into Interface/AddOns/. A
# flat zip would scatter 200+ files loose into that folder, which is
# miserable to undo — hence the folder is built explicitly rather than
# zipping the repository root.
#
# What ships is decided by an allow-list, not by excluding what we happen
# to know about today: a new top-level directory should be absent from
# the payload by default rather than silently included. Upstream shipped
# a TypeScript spike directory by accident exactly that way.
#
# Usage: tools/package.sh [--out-dir dist]
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="dist"
[[ ${1:-} == "--out-dir" ]] && OUT_DIR="$2"

# Directories and root files that belong in the addon payload.
DIRS=(Data Libs Locales Sections Shared UI Textures assets)
ROOT_FILES=(ClassCodex.toc icon.tga LICENSE NOTICE.md README.md CHANGELOG.md)
ROOT_GLOBS=('*.lua')

version=$(grep -m1 '^## Version:' ClassCodex.toc | sed 's/^## Version:[[:space:]]*//' | tr -d '\r')
if [[ -z "$version" ]]; then
    echo "could not read ## Version from ClassCodex.toc" >&2
    exit 1
fi
echo "packaging Class Codex $version"

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
payload="$staging/ClassCodex"
mkdir -p "$payload"

for dir in "${DIRS[@]}"; do
    [[ -d $dir ]] || { echo "missing directory: $dir" >&2; exit 1; }
    cp -a "$dir" "$payload/"
done
for file in "${ROOT_FILES[@]}"; do
    [[ -f $file ]] || { echo "missing file: $file" >&2; exit 1; }
    cp -a "$file" "$payload/"
done
for glob in "${ROOT_GLOBS[@]}"; do
    for file in $glob; do
        [[ -f $file ]] && cp -a "$file" "$payload/"
    done
done

# Nothing the allow-list pulled in should carry build or VCS leftovers.
find "$payload" -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
find "$payload" -name '.git*' -prune -exec rm -rf {} + 2>/dev/null || true

# Every file the TOC lists must exist in the payload. A missing one is a
# Lua error when the client loads the addon, not a packaging warning.
missing=0
while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z $line || $line == \#* ]] && continue
    rel="${line//\\//}"
    if [[ ! -f "$payload/$rel" ]]; then
        echo "TOC lists a file the package does not contain: $rel" >&2
        missing=$((missing + 1))
    fi
done < ClassCodex.toc
if (( missing )); then
    echo "$missing file(s) missing from the package" >&2
    exit 1
fi

# And nothing that has no business being in a game folder.
if find "$payload" \( -name '*.py' -o -name '*.ts' -o -name '*.sh' \) -print -quit | grep -q .; then
    echo "package contains tooling files:" >&2
    find "$payload" \( -name '*.py' -o -name '*.ts' -o -name '*.sh' \) >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
zip_path="$OUT_DIR/ClassCodex-$version.zip"
rm -f "$zip_path"
( cd "$staging" && zip -qr9 "$OLDPWD/$zip_path" ClassCodex )

roots=$(unzip -Z1 "$zip_path" | cut -d/ -f1 | sort -u)
if [[ $roots != "ClassCodex" ]]; then
    echo "zip must contain exactly one root folder named ClassCodex, found:" >&2
    echo "$roots" >&2
    exit 1
fi

count=$(unzip -Z1 "$zip_path" | grep -vc '/$' || true)
size=$(du -h "$zip_path" | cut -f1)
echo "wrote $zip_path — $count files, $size"
echo "version=$version"
