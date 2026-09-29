#!/bin/zsh
# install.sh — installs Nidus in /Applications from the latest GitHub release,
# or updates it: run it again for a new version.
#
#   curl -fsSL https://raw.githubusercontent.com/samporter14/nidus/main/install.sh | zsh
#
# macOS only flags apps downloaded through a web browser, so Nidus installed
# this way opens without the "can't verify" prompt. You're trusting this
# script and the release it downloads, so read it first if you like: it's
# short.
#
# NIDUS_INSTALL_DIR installs somewhere else instead, without opening it (for
# testing this script).
set -euo pipefail

DIR="${NIDUS_INSTALL_DIR:-/Applications}"
APP="$DIR/Nidus.app"
URL="https://github.com/samporter14/nidus/releases/latest/download/Nidus.zip"

if [[ "$(uname -m)" != arm64 ]]; then
    echo "Nidus needs a Mac with Apple silicon (M1 or later)." >&2
    exit 1
fi
if (( $(sw_vers -productVersion | cut -d. -f1) < 27 )); then
    echo "Nidus needs macOS 27 or later." >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Downloading Nidus…"
curl -fsSL "$URL" -o "$TMP/Nidus.zip"
ditto -x -k "$TMP/Nidus.zip" "$TMP"
if [[ ! -d "$TMP/Nidus.app" ]]; then
    echo "The download didn't contain Nidus.app. Try again later." >&2
    exit 1
fi

# Only the copy being replaced is quit, by its path; any other Nidus is left
# alone. Nidus takes the signal as ⌘Q: a session in progress is saved and
# carries on when the new one opens.
if pgrep -f "$APP/Contents/MacOS/Nidus" >/dev/null; then
    echo "Quitting the running Nidus…"
    pkill -TERM -f "$APP/Contents/MacOS/Nidus" || true
    for _ in {1..20}; do
        pgrep -f "$APP/Contents/MacOS/Nidus" >/dev/null || break
        sleep 0.5
    done
    if pgrep -f "$APP/Contents/MacOS/Nidus" >/dev/null; then
        echo "Nidus is still running. Quit it with ⌘Q, then run this again." >&2
        exit 1
    fi
fi

rm -rf "$APP"
mv "$TMP/Nidus.app" "$APP"
echo "Installed Nidus $(defaults read "$APP/Contents/Info" CFBundleShortVersionString) in $DIR."
if [[ -z "${NIDUS_INSTALL_DIR:-}" ]]; then
    open "$APP"
fi
