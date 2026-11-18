# Changelog

## [1.0.1]

- A new menu-bar icon: a window with a tide curling inside it, after the app icon. Clear at menu-bar size in light
  and dark.
- A promo video, in the README and on the release.

## [1.0.0]

The first release as **Tidewall** (formerly Driftland, a fork of Deskland).

### The app
- A real macOS app with its own icon: lives in the menu bar, and in the Dock while its window is open.
- The Tidewall window: every theme with a **live preview** of your own desktop (your screen's shape, your windows,
  Stage Manager and widgets; drag the windows to watch the theme re-flow), variant pickers, per-display themes,
  settings, and what the wallpaper is costing right now. The window's memory is freed when you close it.
- Opening Tidewall again shows the running copy's window instead of starting a second one; the login item follows
  the app if you move it.
- Settings from Driftland are carried over on first launch.

### Themes
- **Model Railway**: a toy railway diorama. Windows become towns with ring roads and houses; one main line loops the
  board with stations and passing loops, branch lines run to outlying villages, country roads cross the line at level
  crossings whose barriers drop for trains. The board redraws only when windows change.
- **Celestial Atlas** shows the sky over the city of your time zone (it was fixed to New Delhi).
- 13 themes in all: Model Railway, Garden Plan, Marauders, Gallery, Ink Map, Celestial Atlas, Snowfall, Lava Lamp,
  Wind Map, Koi Reef, Wind Tunnel, Meadow and Beach.

### Lighter
- All screens share one web process; wallpapers pause after 3 minutes without input and are released to still
  pictures after 10 (or 90 seconds after locking), and come back on the first touch.
