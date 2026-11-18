# Changelog

## [1.0.3]

- **The Tidewall window can be moved again**: drag it by its top edge or the empty top of the sidebar (double-click
  there to zoom, as in any Mac app).
- **Updates live in About** now, next to the version: Check now, Restart to Update, and the Update automatically switch.
- **Pause is remembered** across restarts (including an update installed while the screen is locked), and a wallpaper
  that starts paused still lays itself out around your windows before it freezes.
- **Changing the theme while paused** now shows the new theme straight away (it used to wait until you resumed).
- In the gallery, **Return applies the card you've tabbed to**, and the arrow keys move exactly one row at any width.
- **Plugging a display in or out** updates the open Tidewall window at once.
- The menu bar ticks **every theme that's on a display**; a main display with its own theme reads "Default (…)".
- **Desktop widgets are recognised on every Mac** (by Notification Center's bundle id, not its localised name), so
  they're no longer drawn as ordinary windows in the preview.
- **Open at login** shows when macOS has switched Tidewall off in System Settings ▸ Login Items, and takes you there.
- Two identical monitors are told apart; long display names have a tooltip; the preview can't show a stale frame while
  you browse quickly; switches and theme cards work with VoiceOver; Lava Lamp counts as battery friendly; clearer
  wording for Rest when idle and for the GPU meter while the window is open.

## [1.0.2]

- **Tidewall now updates itself.** It checks GitHub for new versions (at launch and every 6 hours), downloads them in
  the background, verifies each one is a genuine signed Tidewall release, and installs it while your screen is locked.
  Or choose **Restart to Update** in the menu bar. Turn it off in Settings ▸ Updates; **Check for Updates…** is in the
  menu. *Coming from 1.0.1? Download this one by hand and open it: it replaces the running copy and offers to move itself to Applications. Every update after this installs itself.*
- **Opened from Downloads, Tidewall offers to move itself to Applications** (where it can open at login and update
  itself), then carries on from there. It never replaces a newer copy already installed.
- The menu-bar CPU and memory now show what the wallpaper costs; the Tidewall window's own page is listed apart (and
  freed when you close it). Reading GPU use is ~20× cheaper, and the window's meters stop while it's hidden.

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
