#!/usr/bin/env bash
# scripts/release.sh
#
# Bump version → build Rust core → build Release .app → Developer-ID sign
# (hardened runtime) → notarize + staple → zip + DMG → tag → publish a
# GitHub release → Sparkle-sign the zip and push a new appcast.xml item.
#
# The app is signed with a Developer ID Application certificate (team
# $TEAM_ID), hardened-runtime enabled, then submitted to Apple's notary
# service and the ticket stapled onto both the .app and the .dmg. Result:
# Gatekeeper opens it with no right-click dance and no quarantine prompt,
# even offline.
#
# Sparkle: installed copies poll appcast.xml on main (SUFeedURL in
# Config/Info.plist). The appcast commit is pushed only AFTER the GitHub
# release exists, so the feed never points at a download that isn't live.
# The EdDSA private key (shared with Perch / ZedisUI) must be in the login
# keychain; `sign_update` reads it from there.
#
# One-time machine setup (already done for Noticky on this Mac):
#   • Developer ID Application cert for team $TEAM_ID in the login keychain
#       (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID).
#   • A notarytool credential profile, stored once with:
#       xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#           --apple-id <you@apple> --team-id $TEAM_ID --password <app-specific-pw>
#   • The team's Apple Developer Program License Agreement must be current —
#       if notarytool returns 403 "a required agreement is missing or has
#       expired", accept the updated agreement at developer.apple.com /
#       App Store Connect before releasing.
#
# Usage:
#   ./scripts/release.sh <version> [--notes-file <path>] [--dry-run]
#
# Examples:
#   ./scripts/release.sh 0.0.1
#   ./scripts/release.sh 0.0.1 --notes-file docs/release-notes-0.0.1.md
#   ./scripts/release.sh 0.0.1 --dry-run
#
set -euo pipefail

# Resolve repo root from the script's own location so it runs from anywhere.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ── Project constants ───────────────────────────────────────────────
SCHEME="PcsuiteMirror"
PROJECT="PcsuiteMirror.xcodeproj"
PRODUCT="PcsuiteMirror"
RUST_DIR="../pcsuite-rs"
RUST_BUILD="${RUST_DIR}/crates/pcsuite-ffi/build-macos.sh"
BUILD_DIR="build/DD"            # xcodebuild derivedData (gitignored)
GH_REPO="PcsuiteMirror/PcsuiteMirror"   # must match SUFeedURL in Config/Info.plist
APPCAST="appcast.xml"
SU_PLIST="Config/Info.plist"    # partial Info.plist carrying SUFeedURL / SUPublicEDKey
# sign_update / generate_keys ship in the Sparkle SPM artifact bundle.
SPARKLE_BIN_DIR="${BUILD_DIR}/SourcePackages/artifacts/sparkle/Sparkle/bin"

# Developer ID / notarization. TEAM_ID + NOTARY_PROFILE are shared with the
# author's other notarized apps; override NOTARY_PROFILE via env if you stored
# the credentials under a different name.
TEAM_ID="T8F5T6HKG8"
NOTARY_PROFILE="${NOTARY_PROFILE:-noticky-notary}"

# ── Args ────────────────────────────────────────────────────────────
usage() {
    cat <<EOF >&2
Usage: $(basename "$0") <version> [--notes-file <path>] [--dry-run]

  <version>          CFBundleShortVersionString, e.g. 0.0.1
  --notes-file PATH  File whose contents become the GitHub release body
                     (default: gh --generate-notes from commit messages).
  --dry-run          Bump version + build + Developer-ID sign + package
                     locally, but SKIP notarization, commit, push, tag and
                     the GitHub release. Reverts the version bump afterwards
                     so the tree stays clean.
EOF
    exit 1
}

VERSION=""
NOTES_FILE=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --notes-file)  NOTES_FILE="${2:?--notes-file needs a path}"; shift 2 ;;
        --dry-run)     DRY_RUN=true; shift ;;
        -h|--help)     usage ;;
        -*)            echo "Unknown flag: $1" >&2; usage ;;
        *)
            if [[ -z "$VERSION" ]]; then VERSION="$1"; shift
            else echo "Unexpected positional: $1" >&2; usage; fi
            ;;
    esac
done

[[ -z "$VERSION" ]] && usage
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "ERROR: version must be X.Y.Z (got '$VERSION')" >&2; exit 1; }

TAG="v${VERSION}"
TITLE="v${VERSION}"
DIST_DIR="dist/${TAG}"
ZIP_ASSET="${PRODUCT}-${VERSION}.zip"
DMG_ASSET="${PRODUCT}-${VERSION}.dmg"
ZIP="${DIST_DIR}/${ZIP_ASSET}"
DMG="${DIST_DIR}/${DMG_ASSET}"
APP="${DIST_DIR}/${PRODUCT}.app"

echo "==> Version $VERSION  •  Tag $TAG  •  Assets $ZIP_ASSET + $DMG_ASSET"

# ── Pre-flight ──────────────────────────────────────────────────────
echo "==> Pre-flight checks"

[[ -f project.yml ]] || { echo "ERROR: run from repo root (no project.yml)" >&2; exit 1; }
[[ -x "$RUST_BUILD" ]] || { echo "ERROR: Rust build script not found/executable: $RUST_BUILD" >&2; exit 1; }

command -v xcodegen >/dev/null || { echo "ERROR: xcodegen not on PATH (brew install xcodegen)" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "ERROR: xcodebuild not on PATH (install Xcode)" >&2; exit 1; }
command -v cargo >/dev/null || { echo "ERROR: cargo not on PATH (install Rust)" >&2; exit 1; }

# Developer ID Application signing identity for our team (needed for both real
# and dry runs, since we sign in both). Resolve to the SHA-1 hash so codesign
# can't pick the wrong cert when several are installed.
DEV_ID_HASH="$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | grep "(${TEAM_ID})" | head -1 | awk '{print $2}')"
if [[ -z "$DEV_ID_HASH" ]]; then
    echo "ERROR: no 'Developer ID Application' cert for team ${TEAM_ID} in the login keychain." >&2
    echo "       Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application." >&2
    exit 1
fi
DEV_ID_NAME="$(security find-identity -v -p codesigning \
    | grep "$DEV_ID_HASH" | head -1 | sed -E 's/.*"(.+)"$/\1/')"
echo "    signing identity: ${DEV_ID_NAME}"

if [[ "$DRY_RUN" == "false" ]]; then
    command -v gh >/dev/null || { echo "ERROR: gh CLI not on PATH (brew install gh)" >&2; exit 1; }
    gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated. Run 'gh auth login'." >&2; exit 1; }

    # Notary credentials must work AND the team's agreement must be current.
    # `notarytool history` surfaces a 403 agreement error before we build.
    echo "    checking notary profile '${NOTARY_PROFILE}'…"
    if ! NOTARY_CHECK="$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1)"; then
        echo "ERROR: notarytool profile '${NOTARY_PROFILE}' is unusable:" >&2
        echo "$NOTARY_CHECK" | sed 's/^/       /' >&2
        echo "       If this is a 403 'required agreement' error, sign in at" >&2
        echo "       https://developer.apple.com/account and accept the updated" >&2
        echo "       Program License Agreement, then retry." >&2
        echo "       If credentials are missing, set them up once with:" >&2
        echo "         xcrun notarytool store-credentials ${NOTARY_PROFILE} \\" >&2
        echo "             --apple-id <id> --team-id ${TEAM_ID} --password <app-specific-pw>" >&2
        exit 1
    fi

    [[ -z "$(git status --porcelain)" ]] \
        || { echo "ERROR: working tree dirty. Commit or stash first." >&2; git status --short >&2; exit 1; }

    if git rev-parse --verify "refs/tags/${TAG}" >/dev/null 2>&1; then
        echo "ERROR: tag ${TAG} already exists locally." >&2; exit 1
    fi
    if git ls-remote --tags origin "${TAG}" | grep -q "refs/tags/${TAG}$"; then
        echo "ERROR: tag ${TAG} already exists on origin." >&2; exit 1
    fi
fi

if [[ -n "$NOTES_FILE" ]]; then
    [[ -f "$NOTES_FILE" ]] || { echo "ERROR: --notes-file not found: $NOTES_FILE" >&2; exit 1; }
fi

# ── Sparkle pre-flight ──────────────────────────────────────────────
[[ -f "$APPCAST" ]] || { echo "ERROR: $APPCAST missing — Sparkle needs it. Restore from git." >&2; exit 1; }
grep -q "BEGIN-ITEMS" "$APPCAST" \
    || { echo "ERROR: $APPCAST has no BEGIN-ITEMS marker; refuse to mangle it." >&2; exit 1; }
# An empty key would make Sparkle accept unsigned updates — refuse.
ED_PUBKEY="$(plutil -extract SUPublicEDKey raw -o - "$SU_PLIST" 2>/dev/null || true)"
[[ -n "$ED_PUBKEY" ]] || { echo "ERROR: SUPublicEDKey missing from $SU_PLIST" >&2; exit 1; }

# The project is gitignored and project.yml may have changed; regenerate, then
# resolve SPM so the Sparkle tools exist before anything gets bumped.
xcodegen >/dev/null
echo "==> Resolving SPM packages (Sparkle tools)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -derivedDataPath "$BUILD_DIR" \
    -resolvePackageDependencies >/dev/null
[[ -x "${SPARKLE_BIN_DIR}/sign_update" ]] \
    || { echo "ERROR: Sparkle sign_update not at ${SPARKLE_BIN_DIR}/sign_update (SPM resolve failed?)" >&2; exit 1; }
if [[ "$DRY_RUN" == "false" ]]; then
    # `generate_keys -p` prints the public half of the keychain's private key.
    KEYCHAIN_PUBKEY="$("${SPARKLE_BIN_DIR}/generate_keys" -p 2>/dev/null || true)"
    if [[ "$KEYCHAIN_PUBKEY" != "$ED_PUBKEY" ]]; then
        echo "ERROR: Sparkle EdDSA private key in the login keychain doesn't match SUPublicEDKey." >&2
        echo "       keychain: '${KEYCHAIN_PUBKEY}'  plist: '${ED_PUBKEY}'" >&2
        echo "       Restore the shared key (same one Perch/ZedisUI use): generate_keys -f <key.pem>." >&2
        echo "       Do NOT generate a new one." >&2
        exit 1
    fi
fi

# ── Build the Rust static lib + Swift glue ──────────────────────────
echo "==> Building Rust core ($RUST_BUILD)"
"$RUST_BUILD"

# ── Bump version in project.yml ─────────────────────────────────────
current_short=$(grep -E 'MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
current_build=$(grep -E 'CURRENT_PROJECT_VERSION:' project.yml | head -1 | sed -E 's/.*"([0-9]+)".*/\1/')
next_build=$((current_build + 1))

echo "==> Version bump  ${current_short} (build ${current_build}) → ${VERSION} (build ${next_build})"

# BSD sed (macOS) needs a backup suffix with -i; use ".bak" then rm it.
sed -i.bak -E "s/(MARKETING_VERSION: )\"[^\"]+\"/\\1\"${VERSION}\"/" project.yml
sed -i.bak -E "s/(CURRENT_PROJECT_VERSION: )\"[^\"]+\"/\\1\"${next_build}\"/" project.yml
rm -f project.yml.bak

xcodegen >/dev/null

# Revert the version bump (used on build failure and after a dry run).
revert_bump() {
    git checkout -- project.yml 2>/dev/null || true
    xcodegen >/dev/null 2>&1 || true
}

# ── Build the Release .app straight into DIST_DIR ───────────────────
# Build unsigned (CODE_SIGNING_ALLOWED=NO), then Developer-ID sign below with
# hardened runtime — simpler than an archive/exportArchive round-trip and the
# bundle has no nested code to re-sign.
echo "==> Cleaning ${DIST_DIR}"
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

echo "==> Building Release ${PRODUCT}.app (this can take a minute)"
if ! xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -derivedDataPath "$BUILD_DIR" \
        CONFIGURATION_BUILD_DIR="$ROOT/$DIST_DIR" \
        CODE_SIGNING_ALLOWED=NO \
        build 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"; then
    echo "ERROR: Release build failed. Reverting version bump." >&2
    revert_bump
    exit 1
fi

[[ -d "$APP" ]] || { echo "ERROR: built app missing at $APP" >&2; revert_bump; exit 1; }

# Strip the build's sidecar products so only the .app ships in the dir.
rm -rf "${DIST_DIR}/${PRODUCT}.swiftmodule" "${DIST_DIR}/${PRODUCT}.app.dSYM"

# ── Developer-ID sign with hardened runtime ─────────────────────────
# --options runtime → hardened runtime (required for notarization).
# --timestamp       → secure Apple timestamp (also required).
# No --entitlements: the app needs no hardened-runtime exceptions (Rust is
# statically linked; Sparkle is our only embedded framework).
#
# Sparkle.framework's helpers are signed inside-out first, per Sparkle's
# "signing without Xcode" recipe: library validation under hardened runtime
# only loads a framework signed by our own team, and notarization wants every
# nested executable Developer-ID signed with a timestamp. Downloader.xpc keeps
# its own entitlements.
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$SPARKLE_FW" ]] || { echo "ERROR: Sparkle.framework not embedded in $APP" >&2; revert_bump; exit 1; }
echo "==> Developer-ID signing Sparkle.framework"
SIGN=(codesign --force --options runtime --timestamp --sign "$DEV_ID_HASH")
"${SIGN[@]}" "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPARKLE_FW/Versions/B/Autoupdate"
"${SIGN[@]}" "$SPARKLE_FW/Versions/B/Updater.app"
"${SIGN[@]}" "$SPARKLE_FW"

echo "==> Developer-ID signing ${PRODUCT}.app"
codesign --force --options runtime --timestamp --sign "$DEV_ID_HASH" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" \
    || { echo "ERROR: codesign verify failed" >&2; revert_bump; exit 1; }
codesign -d --verbose=2 "$APP" 2>&1 | grep -E "TeamIdentifier|Authority=Developer ID|flags=.*runtime" || true

echo "==> Built arch:"
lipo -info "$APP/Contents/MacOS/${PRODUCT}" 2>&1 || true

# ── Notarize the .app (submit a zip; staple the ticket onto the bundle) ──
if [[ "$DRY_RUN" == "false" ]]; then
    echo "==> Zipping app for notarization"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

    echo "==> Submitting .app to Apple notary (--wait blocks until verdict)"
    NOTARY_LOG="${DIST_DIR}/notary-app.log"
    if ! xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee "$NOTARY_LOG"; then
        echo "ERROR: app notarization failed. See $NOTARY_LOG" >&2
        echo "       Pull details: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE" >&2
        revert_bump
        exit 1
    fi

    echo "==> Stapling ticket onto ${PRODUCT}.app"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
fi

# ── Final zip (must contain the STAPLED app) ────────────────────────
echo "==> Zipping ${ZIP_ASSET}"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# ── DMG (hdiutil; create-dmg not required) ──────────────────────────
echo "==> Creating ${DMG_ASSET}"
DMG_STAGE="${DIST_DIR}/.dmg-stage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
ditto "$APP" "${DMG_STAGE}/${PRODUCT}.app"
ln -s /Applications "${DMG_STAGE}/Applications"
hdiutil create \
    -volname "${PRODUCT} ${VERSION}" \
    -srcfolder "$DMG_STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null
rm -rf "$DMG_STAGE"

# ── Notarize + staple the DMG too ───────────────────────────────────
if [[ "$DRY_RUN" == "false" ]]; then
    echo "==> Submitting .dmg to Apple notary"
    NOTARY_LOG_DMG="${DIST_DIR}/notary-dmg.log"
    if ! xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee "$NOTARY_LOG_DMG"; then
        echo "ERROR: DMG notarization failed. See $NOTARY_LOG_DMG" >&2
        revert_bump
        exit 1
    fi
    echo "==> Stapling DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"

    echo "==> Gatekeeper assessment (should PASS now):"
    spctl -a -t exec -vv "$APP" 2>&1 || true
fi

echo "==> Artifacts:"
echo "    $ZIP  ($(du -h "$ZIP" | cut -f1))"
echo "    $DMG  ($(du -h "$DMG" | cut -f1))"

# ── Dry run stops here ──────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
    echo "==> [dry-run] reverting version bump; skipping notarize / commit / tag / release."
    revert_bump
    echo "    Artifacts under ${DIST_DIR}/ are signed but NOT notarized."
    exit 0
fi

# ── Commit version bump + push ──────────────────────────────────────
echo "==> Committing version bump"
git add project.yml
git commit -m "release: ${VERSION} (build ${next_build})"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: working tree dirty after version-bump commit. Resolve before push." >&2
    git status --short >&2; exit 1
fi

echo "==> Pushing main"
git push origin HEAD

# ── Tag + GitHub release ────────────────────────────────────────────
echo "==> Tagging ${TAG}"
git tag -a "$TAG" -m "$TAG"
git push origin "$TAG"

echo "==> Creating GitHub release"
if [[ -n "$NOTES_FILE" ]]; then
    gh release create "$TAG" \
        --title "$TITLE" \
        --notes-file "$NOTES_FILE" \
        "$ZIP" "$DMG"
else
    gh release create "$TAG" \
        --title "$TITLE" \
        --generate-notes \
        "$ZIP" "$DMG"
fi

# ── Sparkle: sign the .zip + publish the appcast item ───────────────
# Done only now: the zip is live at DOWNLOAD_URL, so installs that fetch the
# feed right after the push can download it. sign_update prints
# `sparkle:edSignature="…" length="…"`.
echo "==> Signing ${ZIP_ASSET} with the Sparkle EdDSA key"
SIGN_LINE="$("${SPARKLE_BIN_DIR}/sign_update" "$ZIP")"
ED_SIG="$(echo "$SIGN_LINE" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')"
ASSET_LEN="$(echo "$SIGN_LINE" | sed -E 's/.*length="([^"]+)".*/\1/')"
if [[ -z "$ED_SIG" || -z "$ASSET_LEN" || "$ED_SIG" == "$SIGN_LINE" ]]; then
    echo "ERROR: failed to parse sign_update output: $SIGN_LINE" >&2
    echo "       The GitHub release exists; fix and add the appcast item by hand." >&2
    exit 1
fi

DOWNLOAD_URL="https://github.com/${GH_REPO}/releases/download/${TAG}/${ZIP_ASSET}"
RELEASE_LINK="https://github.com/${GH_REPO}/releases/tag/${TAG}"

# Inline notes for Sparkle's update window: the --notes-file, else commit
# subjects since the previous tag (minus release chores).
NOTES_MD_FILE="$(mktemp)"
if [[ -n "$NOTES_FILE" ]]; then
    cat "$NOTES_FILE" > "$NOTES_MD_FILE"
else
    PREV_TAG="$(git describe --tags --abbrev=0 "${TAG}^" 2>/dev/null || true)"
    git log ${PREV_TAG:+"${PREV_TAG}..${TAG}"} --no-merges --pretty='- %s' \
        | grep -vE '^- (release|appcast)' > "$NOTES_MD_FILE" || true
fi
[[ -s "$NOTES_MD_FILE" ]] || printf -- '- %s\n' "$TITLE" > "$NOTES_MD_FILE"

echo "==> Updating ${APPCAST}"
python3 scripts/insert_appcast_item.py "$APPCAST" "$TAG" "$VERSION" "$next_build" \
    "$ED_SIG" "$ASSET_LEN" "$DOWNLOAD_URL" "$RELEASE_LINK" "" "$NOTES_MD_FILE"
rm -f "$NOTES_MD_FILE"
xmllint --noout "$APPCAST" || { echo "ERROR: $APPCAST is no longer valid XML — not pushing." >&2; exit 1; }

git add "$APPCAST"
git commit -m "appcast: ${TAG}"
git push origin HEAD

echo
echo "================================================================"
echo "Release ${TAG} done — Developer-ID signed + notarized + stapled"
echo "  .zip : ${ZIP}"
echo "  .dmg : ${DMG}"
echo "  URL  : ${RELEASE_LINK}"
echo "  feed : https://raw.githubusercontent.com/${GH_REPO}/main/${APPCAST}"
echo "================================================================"
