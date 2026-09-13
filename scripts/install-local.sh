#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
"$project_dir/scripts/build-app.sh"
install_dir="$HOME/Applications"
destination="$install_dir/Codex Tokenmaxxing.app"
mkdir -p "$install_dir"
if [ -d "$destination" ]; then
    echo "Quit Codex Tokenmaxxing before replacing it."
    if pgrep -x CodexTokenmaxxing >/dev/null; then
        echo "App is still running; installation stopped." >&2
        exit 1
    fi
    backup_dir="$HOME/Library/Application Support/Codex Tokenmaxxing/Backups/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    mv "$destination" "$backup_dir/"
fi
ditto "$project_dir/dist/Codex Tokenmaxxing.app" "$destination"
open "$destination"
echo "Installed: $destination"
