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
build.sh                → build/Tidewall.app (universal, ad-hoc signed)
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
tools/thumbs.sh <theme>                     # regenerate a gallery thumbnail
tools/mem.sh <theme> [--small]              # memory footprint of a theme's page
./tidewall --bench … --film DIR --film-start S --film-dur S --film-move dx,dy   # promo footage: timestamped 1920 px frames while a window glides
./tidewall --bench … --film DIR --choreo shot.json --timescale 0.4   # scripted desktop (keyframed windows, Stage Manager cards, cursor path)
                                                                       # in slow motion: the page's clocks run 0.4×, so frames play back smooth
./tidewall --ui-only --demo …               # the app window plays a scripted demo (a cursor drags the preview's window)
```

There are no unit tests. Verify by looking: `--bench --snapshot` (and `--frames DIR --every S` for motion, `--hop S`
for a window moving) and read the image. `--bench` prints `window.__dbg()` every 3 s; themes put their state there.
Run benches one at a time; several at once skew each other. Quit any running Tidewall before running `./tidewall`
from source, or two wallpapers stack.

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
