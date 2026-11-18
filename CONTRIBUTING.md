# Contributing to Tidewall

Thanks for wanting to help. Tidewall is a small project: one Swift file for the host (`main.swift`), one HTML page per
theme (`themes/*.html`), and one HTML page for the app window (`themes/ui/index.html`). No package manager, no build
system beyond `swiftc`.

## Getting started

Requires macOS 14+ and the Xcode command-line tools (`xcode-select --install`).

```sh
swiftc -O main.swift -o tidewall -framework Cocoa -framework WebKit -framework IOKit
./tidewall --themes "$PWD/themes"            # run from source (quit any installed Tidewall first)
./tidewall --ui-only --themes "$PWD/themes"  # just the app window, no wallpapers: for working on the interface
./build.sh                                   # the full app: build/Tidewall.app
```

Running with `--themes "$PWD/themes"` serves the theme pages straight from the repo, so edits to a theme show up on
**Reload wallpapers** without rebuilding.

### Testing a theme without touching your desktop

```sh
./tidewall --bench --theme railway --layout cascade --secs 14 --snapshot /tmp/railway.png
```

`--bench` renders one theme against a fixed fake desktop and prints the page's debug line (`window.__dbg()`) every
3 seconds. Useful flags:

| flag | what it does |
|---|---|
| `--layout NAME` | the fake desktop: `sm` (Stage Manager), `tiled`, `cascade`, `crowded`, `edge`, `widgets`, `showcase`, `empty` |
| `--small`, `--nowin` | one small window / no windows at all |
| `--hop S` | the first window glides somewhere else S seconds before the snapshot (to see the theme re-flow) |
| `--frames DIR --every S --from S` | a numbered snapshot every S seconds (a film strip of motion) |
| `--fakedesk I [--stacked]` | pretend to be screen I of a multi-display desk |
| `--variant ID` | a theme variant (Wind Map region, Lava Lamp colours, Wind Tunnel model) |
| `--profile` | report JS milliseconds per frame |

`tools/mem.sh THEME` measures a theme's memory footprint, and `tools/bench.sh` its CPU and GPU time.

## Writing a theme

A theme is a single HTML page in `themes/`. The host loads it in a full-screen web view behind your windows (one per
display) at `tidewall://app/<page>.html?wallpaper=1`, plus `&v=<variant>` if the theme has variants and
`&site=&lat=&lon=&tz=` (the city of the user's time zone, for themes that need to know where they are).

### What the page must do

- Set `window.__noMask = true` (themes draw everything themselves).
- Define the globals the host's test probe reads: `FB`, `commit()`, `refresh()`, `P` (an object), `fieldMs` (a
  number: how long the last expensive redraw took) and `cv` (the main canvas). Dummies are fine:
  `let FB = null; function commit() {} function refresh() {}`.
- Listen for host messages and say it's ready:

```js
const host = window.chrome && window.chrome.webview;
if (host) { host.addEventListener('message', ev => handle(JSON.parse(ev.data))); host.postMessage('ready'); }
else { /* opened in a browser: show a demo layout so the page can be worked on standalone */ }
```

- If the theme ignores the pointer, also `host.postMessage('nocursor')`: the host then stops sending cursor messages
  (which arrive at up to 120 Hz).

### Messages from the host

All coordinates are **device pixels** relative to the page (CSS pixels × `devicePixelRatio`).

| `t` | fields | when |
|---|---|---|
| `desk` | `x y w h` (this screen in the desk, points), `uw uh` (whole desk), `i n` (this screen's index and the count, in reading order), `mx my mw mh` (the main display) | first, and when displays change. Use it to continue one world across screens. |
| `me` | `seed` | a stable per-user random seed |
| `windows` | `r: [[x0,y0,x1,y1]…]`, `n: [app names]`, `sm: [0/1…]` (Stage Manager card?), `live` (a window is being dragged) | whenever windows change |
| `icons` | `vis`, `r` | the same windows grown by the user's margin setting (older themes use this) |
| `cursor` | `x y` | the pointer moved over this screen |
| `cursorOff` | | the pointer left this screen |
| `pause` | `v` | stop or resume animating (screen covered, idle, locked, user pause). Stop your `requestAnimationFrame` loop. |

### Being a good wallpaper

Tidewall runs all day behind everything, so cost matters more than anything else. The cheap themes (Ink Map, Garden
Plan, Model Railway) all follow one recipe:

1. **Draw the scene once**, into one canvas, and redraw it only when the windows change. While windows move, redraw a
   few times a second at most and let a CSS opacity transition blend the new picture over the old one.
2. **Move small things with the compositor**: trains, boats, people are small `<canvas>` elements moved with
   `transform: translate3d(…)`. The GPU slides them for free; nothing is redrawn.
3. **Stop when hidden**: honour `pause`, and stop the animation loop when nothing is moving.
4. **Measure**: `--bench --profile`, and `tools/mem.sh`. On WebKit, the cost of a 2D canvas is often in the raster
   *flush*, not your JavaScript: thousands of scaled `drawImage` calls are expensive; pre-scale sprites once.

### Adding it to the app

1. `main.swift`: add the theme to `Cfg.themes` (id and "Name · cost") and, if the page name differs from the id, to
   the page map in `Wallpaper.load()`.
2. `themes/ui/index.html`: add it to `THEMES` (name, page, cost 0–4, filter tags, description).
3. A thumbnail: `tools/thumbs.sh <id>` renders it on the `showcase` desktop into `themes/ui/thumbs/<id>.jpg`.
4. Variants (optional): add them to `themes/variants.json`; the page reads its choice from `?v=`.
5. Credit any third-party data, art or models in `THIRD_PARTY_NOTICES.md`, with their licence. Only include assets you
   are allowed to redistribute under GPL-3.0-compatible terms.

## Pull requests

- Keep changes focused; one theme or one fix per PR.
- Describe what you saw before and after, ideally with a `--bench` snapshot.
- For performance changes, include numbers (`--profile`, `tools/mem.sh`) before and after.
- By contributing you agree your work is licensed under the GPL-3.0, like the rest of the project.
