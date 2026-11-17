# Driftland

A live wallpaper for macOS that reshapes itself around your **windows** — not desktop icons. Move a window and the scene grows, flows and settles around it.

Each theme is a single HTML/WebGL page; a small Swift host shows it behind your windows on every display and tells it where your windows, Stage Manager strip, widgets and cursor are.

## Themes

| Theme | What it is | Cost |
|---|---|---|
| **Marauders** | a castle floor plan on parchment; footprints follow your cursor | very low |
| **Gallery** | a museum wall: every window hangs in a real frame with a brass label; public-domain masterpieces fill the empty wall | none |
| **Garden Plan** | a landscape architect's planting plan: windows become flowerbeds, walks and trees grow round them, gardeners at work | very low |
| **Wind Map** | live surface wind (Open-Meteo) over any country, hand-inked relief, day/night | medium |
| **Lava Lamp** | soft-body wax with real buoyancy, heat and coalescence; 9 colourways | low |
| **Wind Tunnel** | a GPU lattice-Boltzmann fluid simulation in a smoke tunnel, around real museum-scanned models | high |
| **Koi Reef** | a reef that grows and recedes around your windows; koi, reef fish, caustics | medium |
| **Snowfall** | a painted moonlit valley; snow settles on your windows | low |
| **Celestial Atlas** | the real sky overhead right now, as an antique star chart; windows are black holes | none |
| **Ink Map** | an inked archipelago; a little boat sails to your cursor | very low |
| **Meadow**, **Beach** | painted landscapes that part around your windows | medium–high |

Several displays are one desk: the sky, the wind map and the snow panorama continue across screens, and each display can have its own theme (menu ▸ Displays).

## Build and run

Requires macOS 14+ and the Xcode command-line tools.

```sh
swiftc -O main.swift -o driftland -framework Cocoa -framework WebKit -framework IOKit
./driftland
```

A menu-bar icon (waves) chooses the theme, its variant (region, colours, model), frame rate and start-at-login. No permissions are needed: window positions come from `CGWindowListCopyWindowInfo`.

`./driftland --bench --theme <name> [--layout sm|tiled|cascade|crowded|edge|widgets|empty] --snapshot out.png` renders a theme against a fixed test desktop.

## Credits and licence

Driftland is a fork of [Deskland](https://github.com/BLEZZ0102/Deskland) and, like it, is licensed under the **GNU GPL v3** (see `LICENSE` and `NOTICE`). Data, models, paintings, fonts and libraries keep their own licences — Natural Earth, Open-Meteo, d3-celestial, three.js, the Smithsonian, NASA, Poly Haven, Khronos and The Met; see `THIRD_PARTY_NOTICES.md`.
