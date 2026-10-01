#!/bin/zsh
# build-app.sh — build Nidus.app into ./build (release, this Mac's
# architecture, ad-hoc signed). Usage: Scripts/build-app.sh [--open]
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"

# One build at a time: a second run would delete the app while the first one
# signs or opens it.
mkdir -p build
LOCK="$ROOT/build/.build-app.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    echo "Another build-app.sh is already running. Wait for it to finish (or delete $LOCK if none is)." >&2
    exit 1
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift build -c release --product Nidus
BIN="$(swift build -c release --product Nidus --show-bin-path)/Nidus"

APP="$ROOT/build/Nidus.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Nidus"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# The icon: an Icon Composer document, Nidus's own in Solanum's product
# family (amber tile, the broken ring, five ribbons; Scripts/render-icon.swift
# draws the layer), compiled. actool is given absolute paths only (its helper
# resolves relative ones against wherever another run started it).
ICON="$ROOT/Resources/AppIcon.icon"
if [ -d "$ICON" ]; then
    WORK="$(mktemp -d "${TMPDIR:-/private/tmp}/nidus-icon.XXXXXX")"
    cp -R "$ICON" "$WORK/AppIcon.icon"
    xcrun actool "$WORK/AppIcon.icon" --compile "$APP/Contents/Resources" \
        --app-icon AppIcon --output-partial-info-plist "$WORK/partial.plist" \
        --platform macosx --minimum-deployment-target 27.0 --target-device mac \
        --output-format human-readable-text >/dev/null || echo "warning: icon not compiled"
    rm -rf "$WORK"
fi

# Signed with "Solanum Code Signing" when this Mac has that certificate (a
# self-signed one in the login keychain): the signature then names the
# certificate rather than this exact build, so macOS keeps the permissions it
# granted (microphone, browser control) across updates. Without it, ad-hoc,
# as anyone building from source gets.
IDENTITY=$(security find-certificate -c "Solanum Code Signing" -Z 2>/dev/null | awk '/SHA-1/ {print $3; exit}' || true)
if [[ -n "$IDENTITY" ]]; then
    codesign --force --sign "$IDENTITY" "$APP" >/dev/null
else
    codesign --force --sign - "$APP" >/dev/null
fi
echo "Built $APP"
[[ "${1:-}" == "--open" ]] && open "$APP"
exit 0
