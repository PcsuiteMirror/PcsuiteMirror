---
name: release-app
description: Cut and publish a new PcsuiteMirror release — bump version, build, Developer-ID sign, notarize, tag, and create the GitHub release. Use when asked to release, publish, or ship a new version. This publishes publicly and pushes to git; confirm the version number with the user first.
---

Releasing runs `scripts/release.sh`, which does the whole chain end to end:
bump version → build Rust core → Release build → Developer-ID sign (hardened
runtime) → notarize + staple the `.app` → zip + dmg → notarize + staple the
`.dmg` → commit the version bump → push `main` → tag `vX.Y.Z` → create a GitHub
release with both assets attached → Sparkle-sign the zip (`sign_update`) → insert
an `<item>` into `appcast.xml` → commit `appcast: vX.Y.Z` → push `main`.

Installed copies update through Sparkle 2, polling `appcast.xml` on `main`
(`SUFeedURL` in `Config/Info.plist`). The EdDSA key is the one Perch/ZedisUI use;
its private half must be in the login keychain (the script checks
`generate_keys -p` against `SUPublicEDKey`). Never generate a new key. The
release notes file also becomes the notes in Sparkle's update window.

**`--dry-run` reverts `project.yml` with `git checkout`** — commit any
`project.yml` edits first or they are lost.

**This is outward-facing and hard to undo** (public GitHub release, pushed tag +
commits). Confirm the version number with the user before running the real
release. All commands run from the repo root.

## Step 1 — pick the version, confirm it's new

The script takes `X.Y.Z` and **auto-increments the build number** itself. The tag
`vX.Y.Z` must not already exist (the script refuses to reuse one):

```bash
git tag -l | sort -V                 # existing releases
git log --oneline "v$(git tag -l | sort -V | tail -1 | sed 's/^v//')"..HEAD   # unreleased commits
```

Next version is normally the patch bump above the latest tag (e.g. after `v0.0.2`
→ `0.0.3`). Confirm with the user, since it names a public tag and release.

## Step 2 — write release notes and commit them

Releases ship hand-written notes, one file per version, matching the existing
style. Read the previous one and follow its structure (sections: a one-line
intro, `### New` / `### Fixed`, `### Requirements`, `### Install`, `### License`):

```bash
ls docs/release-notes-*.md          # prior notes to match
```

Write `docs/release-notes-X.Y.Z.md` summarizing the unreleased commits, then
commit it **before** running the release (the script requires a clean tree):

```bash
git add docs/release-notes-X.Y.Z.md
git commit -m "release notes X.Y.Z"
```

## Step 3 — pre-flight the credentials

The script's own pre-flight checks these and fails early if any is off, but
checking first avoids a wasted build:

```bash
gh auth status                                              # must be logged in
xcrun notarytool history --keychain-profile noticky-notary  # notary creds + current Apple agreement
security find-identity -v -p codesigning | grep 'Developer ID Application.*T8F5T6HKG8'
git status --porcelain                                      # must be empty (clean tree)
```

- Notary profile is `noticky-notary` (override with `NOTARY_PROFILE=…`).
- Signing team is `T8F5T6HKG8`. A 403 "required agreement" from notarytool means
  someone must re-accept the Program License Agreement at developer.apple.com.

## Step 4 — dry run first when unsure

`--dry-run` builds + signs + packages locally but **skips** notarize, commit,
push, tag, and the GitHub release, and reverts the version bump so the tree stays
clean. Good for validating a build/signing change without publishing:

```bash
./scripts/release.sh X.Y.Z --dry-run
```

## Step 5 — the real release

The two Apple notarization round-trips are slow (a few minutes each), so run it in
the background and watch for the verdict / any `ERROR`. **Note:** redirect to a
log file — the script's real output is verbose:

```bash
LOG="$SCRATCHPAD/release-X.Y.Z.log"   # or any temp path
./scripts/release.sh X.Y.Z --notes-file docs/release-notes-X.Y.Z.md > "$LOG" 2>&1 &
```

Watch the log for these milestones (all must appear):
`** BUILD SUCCEEDED **` → `Authority=Developer ID Application` → `.app` `status:
Accepted` → `.dmg` `status: Accepted` → `Gatekeeper … accepted` →
`Release vX.Y.Z done` + the release URL. The `appcast: vX.Y.Z` commit comes right
before that final line — if `sign_update` fails, the GitHub release already
exists and the appcast item has to be added by hand.

## Step 6 — verify the publish landed

```bash
gh release view vX.Y.Z --json name,tagName,assets --jq '{name,tagName,assets:[.assets[].name]}'
git status --porcelain && echo "(tree clean)"
[ "$(git rev-parse HEAD)" = "$(git rev-parse @{u})" ] && echo "in sync with origin/main"
```

Expect both `PcsuiteMirror-X.Y.Z.dmg` and `.zip` assets, a clean tree, and HEAD
in sync with origin.

## Gotchas

- **Tree must be clean** before the real run — commit the release-notes file (and
  anything else) first, or the pre-flight aborts.
- **The version bump is a separate commit** the script makes (`release: X.Y.Z
  (build N)`); it pushes both that and your notes commit. Don't bump `project.yml`
  yourself.
- **On any build/notarize failure the script auto-reverts the version bump** and
  exits non-zero, leaving the tree clean — safe to fix and re-run.
- **`--dry-run` still Developer-ID signs** (both paths sign); it just doesn't
  notarize or publish. The dry-run artifacts under `dist/vX.Y.Z/` are signed but
  NOT notarized.
