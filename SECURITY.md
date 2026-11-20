# Security

Tidewall runs with no special permissions: it reads window positions and app names from
`CGWindowListCopyWindowInfo`, serves its own bundled pages over a private `tidewall://` scheme, and makes no network
requests except Wind Map's public weather data from Open-Meteo.

If you find a security problem (for example a way for a web page to read files outside the app's `themes` folder, or
to drive the app through its window's message bridge), please **don't open a public issue**. Use GitHub's
[private vulnerability reporting](../../security/advisories/new) for this repository instead, with steps to reproduce.
You'll get a reply within a week.

## How updates are verified

- **Signed releases.** Each release's `update.json` is signed with Ed25519 over every field the app acts on: the
  version, the zip's SHA-256 and size, the minimum macOS and the notes
  (`tidewall-update-v1\n<version>\n<sha256>\n<size>\n<minOS>\n<sha256(notes)>`). The app ignores the feed unless
  the signature verifies against one of its public keys (`Updater.publicKeys` in `Sources/Update/Updater.swift`). It then checks the
  downloaded zip's size, hash and signature again, and the bundle id, the version and the code signature, and
  re-checks the unpacked copy's code hash right before installing it.
- **Two keys.** CI signs with the first. The second is an offline backup that is never on GitHub, for the day the first
  is lost or has to be retired.
- **The key in CI.** The private key is a secret of the `release` environment, which only `v*` tags can use. It is
  read by a job that runs no build scripts and keeps no git credentials. A ruleset stops published `v*` tags from
  being moved or deleted. Fork pull requests never see it.
- **One code-signing identity.** Every release is signed with Tidewall's own self-signed certificate (public part:
  `assets/tidewall-signing-cert.pem`, SHA-1 `1873ADEDF0C5887F95CACECD56B3083687235F7A`), so macOS sees each update as
  the same app and keeps its permissions. Its private key is a secret of the `codesign` environment (only `v*` tags),
  read only by the build job, and CI refuses a release not signed with exactly this certificate. It isn't an Apple
  Developer ID, so Gatekeeper still asks once on first install, and holding it alone ships nothing: installed copies
  take only what the update key signed.
- **Safe installs.** The app replaces itself with renames on one volume. Where it can't write to its own folder (a
  standard account) it asks for an administrator's password, and only when you choose Restart to Update. The
  install script goes to that prompt as text, never as a file, and running as root it trusts nothing your account can
  still change: it copies the new app into a folder of its own, checks its code-signature hash there again, parks the
  old copy there too, and touches your caches only as you. If a new version doesn't report that it started within 3
  minutes, the previous one is put back; a version that fails twice isn't installed automatically again.
  `tools/update-test.sh` exercises all of this end to end, the administrator's path included (without a password).
- **No downgrades.** Older versions are never installed.
- **Development builds** (anything not built with `RELEASE=1`) don't update themselves.

Residual risk, by design: whoever controls the release key (or the GitHub account and its release environment) can
ship code to every install that has automatic updates on. Keep 2FA on the account.
