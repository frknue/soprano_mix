#!/bin/bash
# Renders the Folio app icon with scripts/render-app-icon.swift (this repo's copy of
# Soprano's renderer with the `mix` glyph; not synced) and writes
# Sources/SopranoMix/Resources/AppIcon.icns.
# Usage: render-app-icon.sh [png-output]
# The optional argument keeps a copy of the 1024×1024 render at that path.
set -euo pipefail

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [png-output]" >&2
    exit 2
fi

export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export PATH="/opt/homebrew/opt/swift/bin:$PATH"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
icns_path="$repo_root/Sources/SopranoMix/Resources/AppIcon.icns"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/soprano-mix-icon.XXXXXX")"
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

iconset="$work_dir/AppIcon.iconset"
swift "$script_dir/render-app-icon.swift" mix "$iconset"

staged_icns="$work_dir/AppIcon.icns"
/usr/bin/iconutil -c icns -o "$staged_icns" "$iconset"
mkdir -p "$(dirname "$icns_path")"
mv -f "$staged_icns" "$icns_path"
echo "Wrote $icns_path"

if [[ $# -eq 1 ]]; then
    mkdir -p "$(dirname "$1")"
    cp "$iconset/icon_512x512@2x.png" "$1"
    echo "Wrote $1"
fi
