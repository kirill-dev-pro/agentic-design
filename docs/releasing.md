# Releasing

How a version of Agentic Design is built, signed and published, and how installed copies
update. Decisions: [#56–#58](decisions.md#56-a-mac-app-bundle-for-apple-silicon-and-macos-14-one-version-in-the-code).

## What a release contains

A GitHub Release `v<version>` with:

| Asset | For |
| --- | --- |
| `Agentic-Design-<version>-arm64.dmg` | a first install: drag the app into Applications |
| `Agentic-Design-<version>-arm64.zip` | the updater (the same signed `.app`, zipped with `ditto`) |
| `latest.json` | the update manifest: version, zip URL, SHA-256, size, notes |
| `latest.json.sig` | Ed25519 signature (base64) of `latest.json`'s exact bytes |
| `SHA256SUMS` | checksums of the dmg and zip, for people |

Installed apps read `https://github.com/<owner>/<repo>/releases/latest/download/latest.json`
(GitHub redirects `latest` to the newest non-draft, non-prerelease release). The repository
is compiled into the app (`UPDATE_FEED`, set by the workflow from `github.repository`).

## One-time setup

1. **The update signing key.** Already generated (2026-11-01) with
   `updatesign keygen`; the private key (a base64 Ed25519 seed) is on the release
   maintainer's Mac at `~/.config/agentic-design/update-signing-key` (mode 600), never in
   the repository. Its public key is `UPDATE_PUBLIC_KEY` in `src/update.odin`. Add the file's
   content as the repository secret `UPDATE_SIGNING_KEY`:

   ```sh
   gh secret set UPDATE_SIGNING_KEY < ~/.config/agentic-design/update-signing-key
   ```

   Back the file up in a password manager. If it is lost, no installed copy can be
   updated again: a new key means a new public key in the app, which only a manual
   download brings. If it leaks, anyone can sign updates: rotate (new key, new public key,
   a release that users install by hand) at once.

2. **Code signing (optional).** Without a certificate the app is signed ad hoc. That runs
   on Apple Silicon and updates itself, but a downloaded copy is blocked by Gatekeeper on
   first launch (see below). To sign and notarize, the Apple Developer Program account
   holder creates a "Developer ID Application" certificate, exports it with its private key
   from Keychain Access as a `.p12` with a password, and adds these secrets (never in chat
   or in the repository):

   | Secret | Value |
   | --- | --- |
   | `DEVELOPER_ID_P12` | `base64 -i certificate.p12` |
   | `DEVELOPER_ID_P12_PASSWORD` | the `.p12` password |
   | `APPLE_ID` | the Apple ID used for notarization |
   | `APPLE_TEAM_ID` | the 10-character team id |
   | `APPLE_APP_PASSWORD` | an app-specific password (appleid.apple.com → Sign-In and Security) |

   The workflow imports the certificate into a temporary keychain, signs with the hardened
   runtime and a secure timestamp, notarizes the zip and the dmg with `notarytool`, and
   staples the tickets.

## Cutting a release

1. Set the version in `src/version.odin` (`VERSION :: #config(VERSION, "0.2.0")`). It is
   the only place: Info.plist, `--version`, Settings and the update manifest take it from
   there, and the workflow refuses a tag that does not match.
2. Write the notes in `docs/releases/v<version>.md` (Markdown; they become the release
   text and the manifest's `notes`).
3. Commit, then tag and push:

   ```sh
   git tag -a v0.2.0 -m "Agentic Design 0.2.0"
   git push origin main v0.2.0
   ```

4. The `Release` workflow (`.github/workflows/release.yml`) builds on an Apple Silicon
   runner with the pinned Odin release, bundles, signs, packs, writes and signs
   `latest.json`, checks the signature against the public key in the code and publishes
   the release. Installed copies see it within a day, or at once with "Check now".

To hold an update back, publish the release as a draft or a prerelease: `latest` skips
both.

## Continuous integration

`.github/workflows/ci.yml` builds the browser viewer (`tools/build_web.sh`, the engine for
`js_wasm32`) on every push and pull request, on Linux with the pinned Odin release, so a
change to the engine that breaks the WebAssembly build fails there, before the website's
deploy (Bunderhost builds the viewer with `site/scripts/viewer.sh`) would. The macOS app is built by `release.yml` on tags; locally, run
both `./build.sh` and `tools/build_web.sh` before pushing engine changes. The Odin release
is pinned in `release.yml`, `ci.yml` and `site/scripts/viewer.sh`: bump them together.

## Building locally

```sh
# the official Odin release, not Homebrew's (Homebrew links a GLFW built for the newest macOS)
ODIN=/path/to/odin tools/release/build.sh        # -> dist/
```

`tools/release/build.sh` builds `-o:speed` for macOS 14 (`-minimum-os-version:14.0`), checks
the MCP tool list, and runs `tools/release/bundle.sh`, which writes the bundle, signs it
(ad hoc, or `DEVELOPER_ID="Developer ID Application: …"` from the keychain) and packs the
zip and dmg (`NO_DMG=1` skips the dmg). The icon is `assets/icon/AppIcon.icns` (committed),
built by `tools/release/make_icon.sh` from two transparent 1024 px masters: `icon-1024.png`
for 64 px and up, and `icon-small-1024.png`, simplified for 16 and 32 px. `icon.svg` is the
same mark as vector, for the site and docs.

The signing tool:

```sh
odin build tools/release/updatesign -out:build/updatesign -o:speed
export UPDATE_SIGNING_KEY_FILE=~/.config/agentic-design/update-signing-key
build/updatesign pubkey
build/updatesign manifest 0.2.0 <zip-url> dist/Agentic-Design-0.2.0-arm64.zip docs/releases/v0.2.0.md dist/latest.json
build/updatesign sign dist/latest.json
build/updatesign verify "$(build/updatesign pubkey)" dist/latest.json
```

## Testing an update locally

Test windows (`AGENTIC_QUIET=1`) never check for updates. Two variables make one that does,
against a local feed:

- `AGENTIC_UPDATE_TEST=1`: updates on in a quiet window; the socket's `update` method may
  install (it stands in for the user's click), and the relaunch keeps the environment.
- `AGENTIC_UPDATE_URL=http://127.0.0.1:8765/latest.json`: the feed (any URL curl reads,
  `file://` too). The signature check is the same as for the real feed.

```sh
ODIN=… NO_DMG=1 tools/release/build.sh -define:VERSION=0.1.1   # a fake newer version
mkdir -p /tmp/upd/server && cp dist/Agentic-Design-0.1.1-arm64.zip /tmp/upd/server/
build/updatesign manifest 0.1.1 http://127.0.0.1:8765/Agentic-Design-0.1.1-arm64.zip \
  /tmp/upd/server/Agentic-Design-0.1.1-arm64.zip - /tmp/upd/server/latest.json
build/updatesign sign /tmp/upd/server/latest.json
python3 -m http.server 8765 --bind 127.0.0.1 --directory /tmp/upd/server &
ODIN=… NO_DMG=1 tools/release/build.sh                        # 0.1.0, to install
ditto "dist/Agentic Design.app" "/tmp/upd/install/Agentic Design.app"
AGENTIC_QUIET=1 AGENTIC_PORT=4415 AGENTIC_UPDATE_TEST=1 \
  AGENTIC_UPDATE_URL=http://127.0.0.1:8765/latest.json \
  "/tmp/upd/install/Agentic Design.app/Contents/MacOS/agentic-design" /tmp/doc.pen &
# socket 4415: {"method":"update","params":{"action":"check"}}, poll "status" until
# "ready", then "install"; send nothing for 5 s (agents idle) and the window relaunches as 0.1.1
```

The scripted version of this check (and of the tamper cases below) is kept with the tests.
Checked on 2026-11-01: 0.1.0 found, downloaded, verified, installed and relaunched 0.1.1
with its document; and refused a zip with one flipped byte (SHA-256), a manifest edited to
match it (signature), a manifest signed with another key, and a manifest without a
signature, each time leaving 0.1.0 in place.

## Gatekeeper, quarantine and signing

| | ad hoc (no secrets) | Developer ID + notarized |
| --- | --- | --- |
| Runs on Apple Silicon | yes (arm64 code must be signed; ad hoc is enough) | yes |
| First launch of a downloaded dmg/zip | blocked: the download is quarantined and Apple cannot check it. Right-click → Open, or System Settings → Privacy & Security → Open Anyway (macOS 15+), or `xattr -dr com.apple.quarantine` | opens after the usual "downloaded from the Internet" prompt |
| Run from the download folder | App Translocation: a read-only temporary copy; updates and agent registration refuse and ask to move it to Applications | the same until moved |
| Updates through the app | install and start without a prompt: `curl` does not set the quarantine flag | the same; the new bundle must also pass `codesign --verify` |
| Integrity of updates | Ed25519 manifest signature + SHA-256 + bundle checks | the same, plus Apple's signature |

Notarization needs the Developer ID certificate, the hardened runtime (`--options runtime`)
and a timestamp; the app needs no entitlements (no JIT, no sandbox).
