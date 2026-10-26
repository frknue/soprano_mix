#!/bin/bash
set -euo pipefail

launch_app=true
if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [--build-only]" >&2
    exit 2
fi
if [[ $# -eq 1 ]]; then
    if [[ "$1" != "--build-only" ]]; then
        echo "Usage: $0 [--build-only]" >&2
        exit 2
    fi
    launch_app=false
fi

export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export PATH="/opt/homebrew/opt/swift/bin:$PATH"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

installed_bundle_id="com.soprano.mix"
dev_bundle_id="com.soprano.mix.dev"
dev_app="$repo_root/.build/debug/Soprano Mix Dev.app"
dev_executable="$dev_app/Contents/MacOS/SopranoMix"
quit_timeout_seconds=10

# True while a process runs the Dev bundle's executable.
dev_is_running() {
    pgrep -f -- "$dev_executable" >/dev/null 2>&1
}

# True while the installed Soprano Mix runs (Launch Services; launches nothing and needs
# no Automation permission).
installed_is_running() {
    [[ -n "$(/usr/bin/lsappinfo find bundleid="$installed_bundle_id" 2>/dev/null)" ]]
}

# Quits a running Soprano Mix Dev and waits until its process is gone, so the new build
# replaces it and its routes are torn down first.
quit_dev() {
    dev_is_running || return 0
    echo "Quitting the running Soprano Mix Dev..."
    /usr/bin/osascript -e "quit app id \"$dev_bundle_id\"" >/dev/null 2>&1 || true
    local waited=0
    while dev_is_running; do
        if (( waited >= quit_timeout_seconds * 10 )); then
            echo "Soprano Mix Dev did not quit within $quit_timeout_seconds s; quit it and run $0 again." >&2
            exit 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
}

echo "Building Soprano Mix Dev..."
cd "$repo_root"
swift build

if [[ "$launch_app" == true ]]; then
    quit_dev
fi

"$script_dir/package-app.sh" \
    debug \
    "$dev_app" \
    "$dev_bundle_id" \
    "Soprano Mix Dev"

echo "Created Soprano Mix Dev at $dev_app"

if [[ "$launch_app" == true ]]; then
    # Only one Soprano Mix runs at a time (two would route every app twice): the Dev app
    # quits at launch while the installed app runs.
    if installed_is_running; then
        echo "The installed Soprano Mix is running, and Soprano Mix Dev quits at launch while it does." >&2
        echo "Quit it first (menu bar → Quit Soprano Mix, or: osascript -e 'quit app id \"$installed_bundle_id\"'), then run $0 again." >&2
        exit 1
    fi
    echo "Launching Soprano Mix Dev..."
    open "$dev_app"
fi
