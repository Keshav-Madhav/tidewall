# Tidewall — notes for AI coding assistants

Tidewall is a macOS live wallpaper that reshapes itself around the user's windows. Read `README.md` for what it is
and `CONTRIBUTING.md` for the theme contract (messages, required globals) before changing anything.

## Layout

```
main.swift              the whole native host (one file, AppKit + WebKit, no dependencies)
themes/*.html           one page per theme (HTML + canvas 2D / WebGL2), served over the tidewall:// scheme
themes/<theme>/         that theme's assets (textures, models, data)
themes/ui/index.html    the app window (themes gallery + live preview, displays, settings, about)
themes/ui/thumbs/       gallery thumbnails (tools/thumbs.sh regenerates them)
themes/variants.json    per-theme variants (Wind Map region, Lava Lamp colours, Wind Tunnel model)
assets/                 app icon (Tidewall.icns, icon-1024.png)
tools/                  dev tools: thumbs, page syntax check, memory and GPU measurement
build.sh                → build/Tidewall.app (universal; ad-hoc, or the Tidewall certificate when TIDEWALL_SIGN_ID is set)
```

Inside `main.swift`: `Cfg` (settings, user defaults, the time-zone site), `SchemeHandler` (serves `themes/`),
`earlyScript`/`lateScript` (injected into wallpaper pages), `Wallpaper` (one desktop-level window + web view per
screen; all screens share one web process via `_setRelatedWebView:`), `Tracker` (polls `CGWindowListCopyWindowInfo`),
`Usage` (CPU/GPU/memory meter), `LoginItem` (a LaunchAgent), `AppWindow` (the app window and its JS bridge), `App`
(lifecycle: idle rest, release to still pictures, covered screens, menu), `Bench` (test harness).

## Commands

```sh
swiftc -O main.swift -o tidewall -framework Cocoa -framework WebKit -framework IOKit   # dev build (must have no warnings)
./tidewall --ui-only --themes "$PWD/themes" [--appearance light] [--select railway] [--page settings]   # just the app window
./tidewall --bench --themes "$PWD/themes" --theme railway --layout cascade --secs 14 --snapshot out.png  # render one theme
./build.sh                                  # the app
tools/check-pages.sh                        # syntax-check every page's scripts (CI runs this and build.sh)
tools/smooth.sh [--update] [wall …]         # smoothness through a window move + settle vs tools/smooth-baseline.json
tools/regress.sh [--quick] [--update-visuals]   # the regression suite (release.sh runs it): every wall solo and on 3
                                            # pretend displays, picture checks + a contact sheet, Settings stress
./tidewall --print-report                   # what About ▸ Report a Problem sends (scrubbed log tail included)
./tidewall --bench --behind …               # test windows one level below the desktop (behind your wallpaper) and the
                                            # app window never brought forward: tests run unseen while you work
tools/thumbs.sh <theme>                     # regenerate a gallery thumbnail
tools/mem.sh <theme> [--small]              # memory footprint of a theme's page
./tidewall --bench … --film DIR --film-start S --film-dur S --film-move dx,dy   # promo footage: timestamped 1920 px frames while a window glides
./tidewall --bench … --film DIR --choreo shot.json --timescale 0.4   # scripted desktop (keyframed windows, Stage Manager cards, cursor path)
                                                                       # in slow motion: the page's clocks run 0.4×, so frames play back smooth
./tidewall --ui-only --demo …               # the app window plays a scripted demo (a cursor drags the preview's window)
```

There are no unit tests: `tools/regress.sh` is the safety net (JS errors, crashes, pages that never get ready, blank walls; `tools/visual-check.py` compares each wall with `tools/visual-baseline.json`, and after a deliberate visual change, `--update-visuals` once you have looked at the sheet). Beyond that, verify by looking: `--bench --snapshot` (and `--frames DIR --every S` for motion, `--hop S`
for a window moving) and read the image. `--bench` prints `window.__dbg()` every 3 s; themes put their state there.
Run benches one at a time; several at once skew each other. Quit any running Tidewall before running `./tidewall`
from source, or two wallpapers stack.

## Releasing (and how installed copies update)

1. Add a `## [X.Y.Z]` section to `CHANGELOG.md` (it becomes the release notes and the update's notes). Commit, push.
2. `tools/release.sh X.Y.Z`: checks main is clean and in sync, builds, writes `VERSION`, commits, tags `vX.Y.Z`, pushes.
3. `.github/workflows/release.yml` builds, zips, signs `update.json` with the `TIDEWALL_UPDATE_KEY` secret, verifies it
   against the app's public key, and publishes the release. Installed copies read
   `releases/latest/download/update.json` (launch + every 6 h), download, verify (size, SHA-256, Ed25519, bundle id,
   version, codesign), and swap themselves in while the screen is locked or on "Restart to Update".

- `VERSION` is the only place the version lives (build.sh reads it). `RELEASE=1 ./build.sh` makes a release build;
  a plain `./build.sh` is a development build (compiled with `-D TIDEWALL_DEV`): it never updates itself and is the only
  kind that honours the `TIDEWALL_UPDATE_*` test variables.
- The key lives in the `release` environment (v* tags only). The publish job runs no repo build scripts. The
  "Protect release tags" ruleset means a pushed `vX.Y.Z` tag can't be moved or deleted: a broken release is fixed
  with the next version, never by re-tagging.
- `Mover` (end of main.swift): opened outside an Applications folder, the app offers once to move itself there
  (resolves App Translocation, never downgrades an installed copy). Release builds only; test it in a dev build with
  `TIDEWALL_UPDATE_MOVE_TEST=1 TIDEWALL_UPDATE_MOVE_DEST=/some/dir`.
- The app window's page fills the title-bar strip and WebKit ignores `-webkit-app-region`, so native `TitlebarDrag`
  strips (top 28 pt, sidebar top 52 pt) move the window. `./tidewall --ui-only --themes "$PWD/themes" --hittest` prints
  which view a click lands on across the top (the traffic lights must stay `_NSTheme…Widget`).
- WebGL themes can lose their GPU context when displays sleep/wake or reconnect; they'd then show only their CSS
  background. `earlyScript` wraps `getContext` in every page: a lost context reports and reloads the page, and
  `checkGPUContexts()` re-checks after wake/unlock/display changes. Test with `--bench … --lose-gl-at 6`.
  (Bench switches for checks like this: `--paused`, `--testpause T`, `--reload-at T`, `--lose-gl-at T`,
  `--resize-at T` (the real display-change path) vs `--resize-raw-at T` (the old behaviour), `--cycle S` (every theme,
  S seconds each: a memory soak), `--fakedesk i --stacked`. Theme ids are the menu's, not file names: Beach is `beach`
  (flat.html). Paused pages are nudged to redraw after a resize: `Wallpaper.redrawIfPaused()`.)
- `log` is a shell function on the maintainer's Mac: read the system log with `/usr/bin/log show …`.
- `Updater.publicKeys` = [CI key, offline backup key]. CI verifies against the first. If you ever sign with the backup,
  change that `sed` in release.yml.
- **Never change `Updater.publicKey` or lose the private key**: every existing install would refuse later updates.
  The private key is the repo secret; keep an offline backup (`tools/update-sign.swift keygen` made it once).
- **Code signing**: releases are signed with a self-signed "Tidewall" certificate (SHA-1 1873ADED…5F7A,
  `assets/tidewall-signing-cert.pem`); the .p12 and its password are the `codesign` environment's `TIDEWALL_SIGN_P12`
  / `TIDEWALL_SIGN_PASS`, with a backup in the maintainer's Keychain ("Tidewall code-signing certificate …"). macOS
  keys Tidewall's permissions to this identity: **never ship a release signed with anything else** (CI checks), and
  changing certificates (or moving to an Apple Developer ID) costs every user one more permission prompt.
- **Quality never drops silently** (the user, 2026-11-20, after 1.1.0's pacer had made transitions jumpy and capped
  them at 60 Hz, and seven walls had been drawn at 1.5×): `tools/smooth.sh` (part of regress.sh) measures every wall's
  frame rate through a window move and its settle against `tools/smooth-baseline.json` and fails a wall that got less
  smooth or stays boosted at rest; regress.sh also fails any wall drawing below the screen's pixel scale (`dpr=` in the
  bench line). Only re-record references (`tools/smooth.sh --update`) after a deliberate, looked-at change, never to
  make a slower wall pass. Save power at rest (calm rates), never mid-transition: a wall that's still changing calls
  `window.__twSettle(150)` each frame until it has settled (full rate, and the check verifies it really got it;
  regress.sh fails if one of the transition walls loses the call). A new wall with a layout transition must do the
  same, and be added to that list in regress.sh. Auto's full rate (drags, settles: `__twBoost`/`__twSettle`) is the display's own
  maximum (`NSScreen.maximumFramesPerSecond`); the pointer over the wallpaper (`__twHover`) gets at most 60; at rest the
  wall's calm rate. Prefer making idle motion slow enough that each calm-rate step is ≤ ~1 retina px (an illusion
  of smoothness for free) over raising calm rates; CSS transitions to glide sprites cost more in WebKit (+5 points of
  CPU on Ink Map, measured) than they save. Measure on mains power with Low Power Mode off.
- **Update tests on your own Mac**: give every test app (clients AND the test release) the Info.plist key
  `TidewallIsolatedTest` = true. Development builds then keep to themselves: settings suite `tidewall.isolated-test`,
  log `Tidewall-isolated-test.log`, updater folder `~/Library/Caches/app.tidewall.isolated-test`, no login-item writes,
  no replacing or signalling the running Tidewall, windows below the desktop level. Without it a test copy (a higher
  version) quits your real Tidewall, takes its login item and writes into `app.tidewall`. Release builds ignore the key.
- Test an update locally without publishing: build a higher version, sign it (`TIDEWALL_UPDATE_KEY=… swift
  tools/update-sign.swift sign …`), serve it with `python3 -m http.server`, then run an installed copy with
  `TIDEWALL_UPDATE_FEED=http://127.0.0.1:PORT/update.json TIDEWALL_UPDATE_INSTALL_NOW=1` (a development build, with a
  throwaway key swapped into `publicKeys`, so you never need the real one locally). The swap is a detached helper (its
  own session and a clean environment). It renames the old app to `.tidewall-update/previous.app` beside it, opens the
  new one and waits 20 s for `~/Library/Caches/app.tidewall/update-alive`. If that doesn't arrive, it rolls back and
  writes `update-result`, which the next launch reads (`update.failed` in defaults).

## Rules the project lives by

- **Cost first.** It runs all day. A theme draws its scene once and redraws only when windows change; moving things
  are small compositor-moved canvases; everything stops on `pause` and when nothing moves. Measure before and after
  (`--profile`, `tools/mem.sh`). Never trade away resolution or render quality to save cost; find the waste instead.
- **Everything moves smoothly.** Nothing pops, blinks or teleports when windows change: things ease, grow, slide or
  cross-fade (one 0.3–0.4 s blend beats many small steps).
- **No permissions.** Window info comes only from `CGWindowListCopyWindowInfo`; location comes from the time zone
  (`/usr/share/zoneinfo/zone.tab`), never CoreLocation. Don't add anything that needs a permission prompt.
- **Privacy.** Only Wind Map uses the network (Open-Meteo, public weather). Don't add telemetry or other calls.
- **Licences.** Every third-party asset must be redistributable under GPL-3.0-compatible terms and credited in
  `THIRD_PARTY_NOTICES.md`.

## Gotchas (each one cost real time)

- On WKWebView a canvas 2D frame's cost is often the **raster flush**, not the JS: hundreds of scaled `drawImage`
  calls (high-quality downscaling) took 70 ms where the JS took 5. Time it with a readback (`getImageData(0,0,1,1)`)
  after drawing; pre-scale sprites once to their on-screen size.
- `file://` pages get an opaque origin (tainted canvases); that's why pages are served over `tidewall://`. Fetch
  responses over the custom scheme have no HTTP status (`r.ok` is false): check the body instead.
- A theme page must define `FB`, `commit`, `refresh`, `P`, `fieldMs` and `cv`, or the host's probe throws an opaque
  "Script error".
- `requestAnimationFrame` stops when a window is offscreen or occluded; benches turn occlusion detection off.
- Slow-changing GPU fields need half-float textures; 8-bit rounds tiny per-frame steps away.
- Editing code with scripts: a `//` comment inserted mid-line silently swallows the rest of that line (shaders too).
- Every bench reads 30 fps on battery: that's macOS Low Power Mode (`pmset -g`), not a regression.
- Open-Meteo: ~10k calls/day and 600 locations/minute; URLs over ~8 KB get 414. Don't test many Wind Map regions back
  to back.
- Stage Manager shrinks a window that isn't frontmost into its strip; screenshots of it then come out tiny.
- `WKProcessPool` no longer does anything (macOS 12+); process sharing is `_setRelatedWebView:`.
- The app window's messages are only accepted from its main frame (`frameInfo.isMainFrame`): theme pages in the
  preview frame can see `webkit.messageHandlers` too.
