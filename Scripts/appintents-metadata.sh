#!/bin/zsh
# appintents-metadata.sh — give an app bundle the App Intents metadata
# Shortcuts reads. Usage: Scripts/appintents-metadata.sh [-c release|debug] <Nidus.app>
#
# Xcode extracts it while building: the compiler writes the intents' constant
# values (.swiftconstvalues), and appintentsmetadataprocessor turns them into
# Contents/Resources/Metadata.appintents. SwiftPM's own build leaves that step
# out, so without this, Shortcuts and Siri never see the actions in
# FocusIntents.swift. `swift build` already writes the constant values (the
# build system passes -emit-const-values and the protocol list for us), so
# this only runs the processor the way Xcode does (see AppIntentsMetadata.xcspec
# in Xcode's SwiftBuild framework for the flags).
#
# Run it after `swift build -c release` and before codesign: the signature
# seals Resources. It needs the build products of this checkout, for the
# same configuration the bundle's binary came from (-c, release by default).
set -euo pipefail

CONFIG=release
if [[ "${1:-}" == "-c" ]]; then
    CONFIG="${2:-}"
    shift 2 || true
fi
APP="${1:-}"
if [[ -z "$APP" || ! "$CONFIG" =~ ^(release|debug)$ ]]; then
    echo "usage: ${0:t} [-c release|debug] <Nidus.app>" >&2
    exit 2
fi
APP="${APP:A}"
ROOT="${0:A:h:h}"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

fail() { echo "appintents-metadata: $*" >&2; exit 1; }

PLIST="$APP/Contents/Info.plist"
[[ -f "$PLIST" ]] || fail "$APP is not an app bundle (no Contents/Info.plist)."
EXECUTABLE="$(plutil -extract CFBundleExecutable raw -o - "$PLIST")"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$PLIST")"
DEPLOYMENT="$(plutil -extract LSMinimumSystemVersion raw -o - "$PLIST" 2>/dev/null || echo 27.0)"
BINARY="$APP/Contents/MacOS/$EXECUTABLE"
[[ -x "$BINARY" ]] || fail "no executable at $BINARY; copy the built binary in first."

# What the compiler needs to have been given: where Xcode keeps these.
PROCESSOR="$(xcrun --find appintentsmetadataprocessor)" || fail "appintentsmetadataprocessor not found; is Xcode installed?"
TOOLCHAIN="${PROCESSOR:h:h:h}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
XCODE_BUILD="$(xcodebuild -version | awk '/^Build version/ {print $3}')"
[[ -n "$XCODE_BUILD" ]] || fail "could not read Xcode's build version."
ARCH="$(uname -m)"
TRIPLE="$ARCH-apple-macosx$DEPLOYMENT"

# The constant values of this build. The output file map names every file the
# compiler wrote for the target (one per source when debugging, one for the
# module when optimizing), so a leftover from a deleted source is never used.
BIN_PATH="$(swift build -c "$CONFIG" --product Nidus --show-bin-path)"
INTERMEDIATES="${BIN_PATH:h:h}/Intermediates.noindex/Nidus.build/${(C)CONFIG}"
MAP="$(find "$INTERMEDIATES" -name Nidus-OutputFileMap.json -path "*/Objects-normal/$ARCH/*" 2>/dev/null | head -1)"
[[ -n "$MAP" ]] || fail "no build products for -c $CONFIG under $INTERMEDIATES; run swift build -c $CONFIG first."

WORK="$(mktemp -d "${TMPDIR:-/private/tmp}/nidus-appintents.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
grep -o '"const-values" *: *"[^"]*"' "$MAP" | sed 's/^"const-values" *: *"\(.*\)"$/\1/' > "$WORK/const-values.txt"
[[ -s "$WORK/const-values.txt" ]] || fail "the build wrote no constant values (see $MAP)."
while IFS= read -r file; do
    [[ -s "$file" ]] || fail "missing constant values $file; run swift build -c $CONFIG again."
done < "$WORK/const-values.txt"
find "$ROOT/Sources/Nidus" -name '*.swift' | sort > "$WORK/sources.txt"

OUT="$APP/Contents/Resources"
mkdir -p "$OUT"
rm -rf "$OUT/Metadata.appintents"
if ! LOG="$("$PROCESSOR" \
        --toolchain-dir "$TOOLCHAIN" \
        --module-name Nidus \
        --sdk-root "$SDK" \
        --xcode-version "$XCODE_BUILD" \
        --platform-family macOS \
        --deployment-target "$DEPLOYMENT" \
        --target-triple "$TRIPLE" \
        --bundle-identifier "$BUNDLE_ID" \
        --binary-file "$BINARY" \
        --output "$OUT" \
        --source-file-list "$WORK/sources.txt" \
        --swift-const-vals-list "$WORK/const-values.txt" \
        --deployment-aware-processing \
        --compile-time-extraction \
        --no-app-shortcuts-localization 2>&1)"; then
    echo "$LOG" >&2
    fail "appintentsmetadataprocessor failed."
fi
# Its routine progress lines are noise; anything else is a warning worth seeing.
print -r -- "$LOG" | grep -v -e 'Starting appintentsmetadataprocessor' -e 'Writing Metadata.appintents' -e 'Metadata root:' >&2 || true

# Well-formed, and listing the actions: a processor that finds nothing still
# exits 0, and an app without metadata is just an app Shortcuts ignores.
META="$OUT/Metadata.appintents"
[[ -f "$META/extract.actionsdata" && -f "$META/version.json" ]] || fail "no metadata written to $META."
ACTIONS="$(plutil -extract actions raw -o - "$META/extract.actionsdata" 2>/dev/null)" || fail "$META/extract.actionsdata is not valid JSON."
[[ -n "$ACTIONS" ]] || fail "the metadata lists no actions; were the intents compiled into this build?"
COUNT="$(print -r -- "$ACTIONS" | wc -l | tr -d ' ')"
echo "Metadata.appintents: $COUNT actions in $META"
print -r -- "$ACTIONS" | sed 's/^/  /'
