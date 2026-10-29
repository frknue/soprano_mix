#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 [--restart]" >&2
    exit 2
}

restart=false
case $# in
    0) ;;
    1) [[ "$1" == "--restart" ]] && restart=true || usage ;;
    *) usage ;;
esac

export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export PATH="/opt/homebrew/opt/swift/bin:$PATH"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
install_root="${SOPRANO_MIX_INSTALL_DIR:-/Applications}"

if [[ "$install_root" != /* || "$install_root" == "/" ]]; then
    echo "SOPRANO_MIX_INSTALL_DIR must be an absolute directory other than /." >&2
    exit 2
fi

echo "Building Soprano Mix for release..."
cd "$repo_root"
swift build -c release

installed_app="$install_root/Soprano Mix.app"
"$script_dir/package-app.sh" \
    release \
    "$installed_app" \
    "com.soprano.mix" \
    "Soprano Mix"

echo "Installed Soprano Mix at $installed_app"

if [[ "$restart" != true ]]; then
    echo "The running app was not restarted; the update takes effect on its next launch (--restart restarts it)."
    exit 0
fi

# PIDs running the installed copy's executable (not the dev build, not another copy).
installed_pids() {
    ps -axo pid=,comm= | awk -v exe="$installed_app/Contents/MacOS/SopranoMix" '
        { pid = $1; sub(/^ *[0-9]+ /, ""); if ($0 == exe) print pid }'
}

wait_for_exit() {
    local tenths=$1
    while (( tenths-- > 0 )); do
        [[ -z "$(installed_pids)" ]] && return 0
        sleep 0.1
    done
    return 1
}

pids="$(installed_pids)"
if [[ -n "$pids" ]]; then
    echo "Quitting the running Soprano Mix ($pids)..."
    # A normal quit first, so pending settings are flushed and the routes stop cleanly.
    for pid in $pids; do
        osascript -l JavaScript -e "ObjC.import('AppKit');
            const app = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid);
            if (app && !app.isNil()) app.terminate;" >/dev/null 2>&1 || true
    done
    # A hung app never answers the quit: end it. Its process taps die with it.
    if ! wait_for_exit 100; then
        echo "It did not quit within 10 s; terminating it."
        kill -TERM $(installed_pids) 2>/dev/null || true
        if ! wait_for_exit 30; then
            kill -KILL $(installed_pids) 2>/dev/null || true
            wait_for_exit 30 || { echo "Could not stop the running Soprano Mix." >&2; exit 1; }
        fi
    fi
fi

open "$installed_app"
echo "Restarted Soprano Mix."
