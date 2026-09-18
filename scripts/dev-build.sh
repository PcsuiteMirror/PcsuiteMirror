#!/usr/bin/env bash
# scripts/dev-build.sh
#
# Build the Debug .app into build/DD and sign it with the team's Developer ID
# certificate — the "dev build" you run straight from build/DD. Nothing is
# zipped, notarized, or copied to dist/; that is release.sh's job.
#
# Why sign a Debug build at all: the Xcode project leaves it ad-hoc signed by
# the linker (CODE_SIGNING_ALLOWED=NO), whose identifier is the product name
# rather than the bundle id and whose identity changes with every build. A
# signature with the release build's team gives the dev build the same stable
# identity, which is a precondition for anything the system grants per app
# (notifications, for one). It is not sufficient on its own: on 2026-09-13 a
# dev build signed this way still had UNUserNotificationCenter answer
# "notifications are not allowed for this application" — see TODO_NEXT.md
# (the likely cause is LaunchServices knowing several copies of the bundle
# id, /Applications among them). Hardened runtime is *not* enabled here: the
# Debug build loads its own debug dylib and previews, which library
# validation would refuse.
#
# Usage:
#   ./scripts/dev-build.sh            # build + sign
#   ./scripts/dev-build.sh --no-rust  # skip the Rust core (Swift-only change)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCHEME="PcsuiteMirror"
PROJECT="PcsuiteMirror.xcodeproj"
BUILD_DIR="build/DD"
APP="$BUILD_DIR/Build/Products/Debug/$SCHEME.app"
RUST_BUILD="../pcsuite-rs/crates/pcsuite-ffi/build-macos.sh"
TEAM_ID="T8F5T6HKG8"        # same team as release.sh

BUILD_RUST=true
for arg in "$@"; do
    case "$arg" in
        --no-rust) BUILD_RUST=false ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

command -v xcodebuild >/dev/null || { echo "ERROR: xcodebuild not on PATH (install Xcode)" >&2; exit 1; }
[[ -d "$PROJECT" ]] || { echo "ERROR: $PROJECT missing — run 'xcodegen generate' first" >&2; exit 1; }

DEV_ID_HASH="$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | grep "(${TEAM_ID})" | head -1 | awk '{print $2}')"
if [[ -z "$DEV_ID_HASH" ]]; then
    echo "ERROR: no 'Developer ID Application' cert for team ${TEAM_ID} in the login keychain." >&2
    echo "       Without it the build stays ad-hoc signed and notifications will not work." >&2
    exit 1
fi

if [[ "$BUILD_RUST" == "true" ]]; then
    echo "==> Building Rust core (release static lib + Swift glue)"
    "$RUST_BUILD"
fi

echo "==> Building Debug $SCHEME.app → $APP"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGNING_ALLOWED=NO \
    build 2>&1 | grep -E "(error:|warning: .*Sources/|BUILD SUCCEEDED|BUILD FAILED)" || true
[[ -d "$APP" ]] || { echo "ERROR: built app missing at $APP" >&2; exit 1; }

echo "==> Signing (team $TEAM_ID, no hardened runtime)"
# Nested code first: the Debug build's own dylibs sit next to the executable,
# and the bundle's signature covers them only once they carry a real one.
for dylib in "$APP"/Contents/MacOS/*.dylib; do
    [[ -f "$dylib" ]] && codesign --force --sign "$DEV_ID_HASH" "$dylib"
done
# Sparkle.framework: the embed step strips its headers without re-signing
# (signing is off in the project), so its original seal is broken. Re-sign
# inside-out, as release.sh does (minus hardened runtime).
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
    codesign --force --sign "$DEV_ID_HASH" "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
    codesign --force --sign "$DEV_ID_HASH" --preserve-metadata=entitlements "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
    codesign --force --sign "$DEV_ID_HASH" "$SPARKLE_FW/Versions/B/Autoupdate"
    codesign --force --sign "$DEV_ID_HASH" "$SPARKLE_FW/Versions/B/Updater.app"
    codesign --force --sign "$DEV_ID_HASH" "$SPARKLE_FW"
fi
codesign --force --sign "$DEV_ID_HASH" "$APP"
codesign --verify --deep --strict "$APP"
codesign -d --verbose=2 "$APP" 2>&1 | grep -E "^(Identifier|TeamIdentifier)=" | sed 's/^/    /'

echo "==> Done: open \"$APP\""
