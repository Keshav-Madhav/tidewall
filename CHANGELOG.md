# Changelog

## [1.3.1]

### Windows: like the Mac
- Opening Tidewall (the Start menu, the desktop shortcut, the end of the install) shows its window, as on a Mac; it
  only stays in the background when it starts with Windows. Before, it opened nothing you could see.
- The tray menu is the Mac's menu-bar menu: what's new, an update ready to install, a live CPU, GPU and memory
  readout, Open Tidewall…, the wall on each display, Pause, Rest when idle, Start with Windows, Check for Updates….
  A click on the tray icon opens the window.
- On battery (or with Battery saver on), Settings ▸ On battery now applies: Calmer draws at half the rate, Pause
  rests the walls. They rest while the PC sleeps.
- Away a while (paused or locked for 90 s, idle for 10 minutes), or hidden 30 s behind a maximised window, a wall
  becomes a still picture and lets go of its memory (about half of Tidewall's), and comes back when it's wanted.
  Switching walls hands over the same way: the old one stays until the new one is drawn, never a bare desktop.
- Settings shows the GPU Tidewall uses, from Windows' own counters.

### Fixed
- On a PC without Microsoft Edge WebView2 (some Windows 10 installs), Tidewall started but couldn't draw anything,
  and said nothing. The installer now adds WebView2 where it's missing, and Tidewall says so if it's still not there.
- Wind Map washed out to a flat grey for half an hour round sunset, as the paper and the ink met half-way. Twilight
  is now its own colour, a deep slate blue under light ink, and the ink turns dark only as the paper brightens.

## [1.3.0]

### Tidewall for Windows
- Every wall now runs on Windows 10 and 11 too, behind your desktop icons: the windows, the icons and the pointer
  shape the scene just as on a Mac, and the walls that span displays draw one world across them. It lives in the
  system tray, with the same Tidewall window (walls with a live preview, displays, settings), an installer that needs
  no administrator, and updates that install themselves. Download it from the website or the release.
- Wind Tunnel now draws on computers without a working graphics card (a virtual machine, a remote session): it spins
  up on a lighter grid there and fades in, rather than staying blank for over a minute.

### Lighter, the picture unchanged
- Ink Map works out far less while a window moves (its fixed islets once, only the land a change reaches), and draws
  each frame once: about a fifth less CPU and two fifths less GPU during a drag.
- Model Railway no longer redraws the whole board every few seconds to change a signal lamp, and draws its icon
  greens and grass from ready-made pieces: a quarter less CPU and half the GPU while windows move.
- Meadow redraws only the boy's corner between cloud updates (half the GPU at rest); Wind Tunnel shades its model
  only inside its box (half the GPU at rest); Estate, Wind Map, Reef, Snowfall, Gallery and Beach drop work they
  repeated for nothing.
- A calm wall no longer wakes at every display refresh to find it isn't due; a drag or the pointer arriving wakes it
  at once, so the first frames of a move come sooner.
- The menu-bar app watches the pointer at 60 Hz only while a wall follows it (it was 120 Hz on every mouse move), and
  looks for windows only every 2 s while everything rests.

### Fixed
- Garden Plan: closing a window re-planted the flowerbeds of every bed after it.

## [1.2.8]

### Ink Map, first
- New installs open on Ink Map, now first in the menu and in Settings. If you never picked a wall, you keep the one
  you've had.
- Ink Map's fields, trees and mountains are always drawn whole; near a forest's edge or a town they used to be cut in
  two. They fade in as the land grows under them.
- The compass rose sits wholly in open water, never half over a coast or off the edge of the screen, and stays away
  when there's no sea big enough for it.

### Fixed
- Started with no windows open, a wall that waits to hear where your windows are (Ink Map among them) drew nothing
  until the first window appeared.

### Small things
- Tidewall has a website, [tidewall.keshav-madhav.com](https://tidewall.keshav-madhav.com/), linked from Settings › About.
- After an update the log says it installed on the same launch, not the next one.
- The log no longer gets a line every second while you drag a window (they crowded out what a problem report needs).
- A leftover from installing updates with an administrator's password is cleared away.

## [1.2.7]

### Steadier, safer updates
- An update gets three minutes, not one, to start before it's rolled back: a slow Mac's first look at a new app can
  take a while. And a version that fails once is tried again later; only one that fails twice waits for a newer one.
- A new version that started but never reported in could clear away the copy it was meant to be rolled back to, and
  the rollback then quietly kept the broken one. The previous copy now stays until the new one has reported in.
- Installing where only an administrator can write (Tidewall installed from another account) no longer trusts
  anything your own account could change between the password prompt and the install: the install script goes to the
  prompt directly, and the new app is copied somewhere private and checked again before it's put in place.
- A new end-to-end test runs a real update before every release: a full download, a patch, the administrator's path,
  a tampered and an unsigned release (both refused) and a rollback.

### Fixed
- If you came from Driftland, its frame rate (often 30) came across with you and, since 1.2.6, held even transitions
  at 30. It's back to Auto, once (unless you've changed it since).
- The walls now see Tidewall's own Settings window like any other window: Ink Map's boat no longer waits underneath it.
- Wind Map put five seas in the wrong place (the Bering Sea off Scotland, the North Pacific in the Sahara). And when the
  free weather service's daily limit is reached, it now says so, drops "LIVE" from its title and slows its stand-in
  air to a drift, instead of a breeze that looked like a forecast.
- Settings described Frame rate as it was before 1.2.6 ("smooths up to 60"); it now says what Auto does: a calm pace at
  rest, every frame your display shows while a window moves or a scene settles, 60 while the pointer is on the wallpaper.
- An update check that got an unreadable answer said "the update feed answered 200"; it now says the update
  information couldn't be read.

### Under the hood
- The app's code is split from one 2,600-line file into small, focused parts, and the scripts every wall runs moved
  into their own files. Release builds no longer carry the test harness, and a mask every wall had switched off is gone.

## [1.2.6]

### Smoother and sharper
- **As smooth as your display, where it shows.** On Auto, a window being dragged and a scene settling after it get as
  many frames as your screen shows: 120 a second on a ProMotion MacBook, 100 on a 100 Hz monitor (since 1.1.0 they had
  stopped at 60, half of what 1.0 drew). The pointer wandering over the wallpaper gets 60, which looks just as smooth
  for things following it and costs less; at rest every wall keeps its calm rate.
- **Ink Map's boat races smoothly.** Sent to a pointer far away, it got the map's calm 30 frames a second and jumped
  up to 8 points a frame. It now gets every frame the display shows while it races (≈2 points a step at 120), and
  where frames are scarce (a lower Frame rate, Calmer on battery) it sails a little slower instead of jumping.
- **Ink Map's ships glide.** At the map's calm 12 frames a second, the ship stepped 2 pixels a frame; it and the sea
  serpent now sail a little slower, so each step is about a pixel and reads as smooth motion, at no extra cost.
- **Full resolution again.** Beach, Meadow, Koi Reef, Snowfall, Wind Map, Wind Tunnel and Lava Lamp had been drawn at
  1.5× (Lava 1.25×) on retina screens since 1.1.0 to save graphics work, which made them soft. Every wall now draws at
  your display's own resolution (a point or two of GPU and some memory more, measured).
- **Islands, beds and towns settle smoothly again.** Since 1.1.0 a wall drops to a slow "calm" frame rate (12 fps on
  Ink Map) to save power once nothing is happening, and it dropped there as soon as you let go of a window, while the
  islands were still growing into their new shape. Now a wall keeps its full frame rate until its change has settled,
  then rests: Ink Map's morph went from ≈30 fps with stalls of 84 ms to ≈60 fps, and Beach, Garden Plan, Marauders and
  Model Railway hold their full rate through the whole transition. Resting costs no more than before.

### Help
- **Report a Problem** (Tidewall ▸ About). Opens a GitHub issue already filled in with what's needed to fix it:
  Tidewall's and macOS's versions, your Mac model, each display and its wall, and your settings. The end of Tidewall's
  log goes on your clipboard, to paste in if you're happy to (it never goes to GitHub by itself). Your name, folders,
  place and coordinates are taken out of both.

### Updates
- **Skipped a release? Still a small download.** Releases now carry patches from the last few versions, not just the
  one before, so a Mac that was off for a couple of releases still fetches only what changed. (Copies from this version
  on; earlier ones read only the newest patch.)
- **Intel Macs get patches too.** They used to check the downloaded patch against the wrong half of the universal app,
  reject it and fetch the whole release every time.

## [1.2.5]

### Updates
- **Tidewall now has its own signature.** Every release from here on is signed with the same Tidewall certificate, so
  macOS recognises each update as the same app and **keeps the permissions you've given it** (Finder, for the desktop
  icons) instead of asking again after every update. This one update is the last time it asks: macOS is meeting the
  signature for the first time.

## [1.2.3]

### Lighter
- **A display covered since Tidewall started now rests too.** A screen under a maximized window from the moment Tidewall
  opened was never drawn on show, so there was no picture of it to leave in its place, and its page kept running. It now
  shows the wall's own picture through the menu bar and lets the page go. With two maximized monitors beside a laptop:
  ≈480 MB → ≈300 MB.
- **Reaching for the menu bar no longer wakes the wallpaper.** The pointer up in the menu bar or the Dock counts as over a
  window, so opening Tidewall's menu (or any other) doesn't make the scene speed up to follow it.

### Honest numbers
- CPU and GPU in the menu and in Settings are now the **average over the last minute**, not the two seconds after you
  opened the menu, which measured the menu drawing itself and the wallpaper reacting to the pointer on its way there.

### Fixed
- A still picture left on a display no longer stretches when its shape differs from the screen's.
- Switching walls quickly no longer fills the log with framebuffer errors from the preview being let go.

## [1.2.2]

### Updates
- **Updates download only what changed.** A release now also carries a small patch of just the files that differ from
  the release before it (often well under 1 MB instead of 130 MB). Tidewall clones itself, lays the patch over the clone,
  and installs it only if the result is exactly the signed release, bit for bit; otherwise it fetches the whole release as
  before. (This version itself still arrives in full: the next one is the first that can come as a patch.)
- **No more “download it from GitHub”.** A copy macOS runs straight from Downloads now offers **Move to Applications**
  (in About and the menu bar) and updates from there. Where Tidewall can't write to its own folder (a standard account,
  an Applications folder only an administrator can change) it still downloads updates, and Restart to Update asks for an
  administrator's password.

### Walls
- Themes are now called **walls**.

### Steadier
- The live preview can no longer sit on “Loading preview…” forever: a wall that doesn't start is tried once more, then
  the window says so. Switching walls lets go of the old preview's graphics at once, and a wallpaper that keeps losing its
  graphics (the GPU reset, say) waits longer before each reload instead of reloading in a loop.

## [1.2.1]

### Lighter
- **A display under a maximized window rests.** When windows cover everything but the menu bar and the Dock, the
  wallpaper there stops drawing (its last frame still shows through the menu bar); after 30 s the page is let go
  entirely, with a still picture in its place, and it comes straight back when a window moves off. (A full-screen app
  already freed its display.) On a desk with two maximized monitors: ≈12% CPU → ≈5%, ≈355 MB → ≈210 MB.
- **While you work in your apps, the wallpaper does far less.** With the pointer over a window, nothing it does there
  can be seen: Celestial Atlas no longer redraws the whole sky for its little black hole (≈13% CPU → ≈1.5%), Ink Map's
  boat holds its course instead of chasing a pointer it can't reach (≈9% → ≈4.5%), and every theme now hears where the
  pointer is 10 times a second there instead of 60.
- **Ink Map at rest** moves its ships at 12 frames a second (about a point a step), and at 30 while the boat is under
  way (≈7% → ≈4.7% CPU).
- **Frame rate 30, 20 or 15 is now a cap**, not a fixed rate: a calm scene that needs less still draws less (with 30
  picked, Ink Map's sea ran at 30 instead of its own 12, Meadow's clouds at 30 instead of 15). 60 still holds every scene
  at 60.
- Celestial Atlas lets go of its working canvases as soon as the minute's sky is painted.

## [1.2.0]

### Your desktop icons
- **Every theme makes room for your desktop icons**, each in its own way: Model Railway lays a village green with a
  hedge round them, Garden Plan a flagstone terrace, Marauders keeps its towers and street names off them, Gallery
  builds them a niche with shelves and hangs the paintings round it, Ink Map and Beach raise an island under them,
  Meadow a bank of cloud, Koi Reef floats each one on a lily pad, Snowfall settles a little cap of snow on each,
  Celestial Atlas sets them in a dark nebula (and letters the sky round them), Wind Map gives them a cartographer's halo
  of bare paper. Lava Lamp leaves them be.
- **Wind Tunnel ▸ No model · your desktop icons**: the icons are the test pieces, and the air comes from their side
  of the screen so their wakes cross it. Chosen for you when you have icons and haven't picked a model.
- The preview in the Tidewall window shows your icons, so you can see what each theme does with them.
- Settings ▸ **Desktop icons** (off until you turn it on). macOS asks to let Tidewall ask Finder where they are; it
  reads their positions only, never their names. *Until Tidewall's updates are signed with a fixed certificate, macOS
  may ask again after an update.*

### More settings
- **What the wallpaper reacts to**: Windows, Stage Manager, Desktop widgets, Desktop icons and The pointer, each its own
  switch. Off, the scene carries on as if that weren't there (the live preview shows it too).
- **Frame rate** gains **60**, the smoothest.
- **On battery**: Same, Calmer (half the frame rate) or Pause, when your Mac is unplugged or in Low Power Mode.
- **Rest when idle** after 1, 3 or 10 minutes, or never.

### Smoother, and fixed
- **Ink Map and Beach reshape smoothly while you drag a window across several displays.** Each display recomputed the
  whole world's coast on every window update (≈45 ms, three times over), so nothing moved until you let go and then
  the land jumped. Now each display works out only the part of its own screen a change reaches, once a frame, and the
  coast follows the window instead of restarting its morph on every update.
- Ink Map no longer cuts a straight channel of sea into the land of a very wide window (a maximized window on a large
  monitor), and coastlines no longer swell into ink blots where two of them nearly touch.
- Celestial Atlas across several displays: the Milky Way and the paper carry straight on across a seam (each display
  used to darken its own edges and cut the band off).
- Wind Map across several displays: names are placed for the whole map, so one crossing a seam is drawn on both sides
  (it used to be cut off); the map darkens toward its own edges, not each display's; and a forecast one display fetches
  reaches the others at once (they could show a stand-in breeze for half a minute).
- Koi Reef: a rare error while displays change size, which could stop its reef growing for a moment.

## [1.1.0]

### One world across your displays
- **Every theme but Lava Lamp and Wind Tunnel now spans displays.** Show one on several displays and it becomes one
  world: one railway network whose trains run from screen to screen, one lagoon whose koi swim between your monitors,
  one archipelago your boat sails across, one garden whose walks join beds on different screens, one sea of sandy
  islands with kayaks crossing it, one meadow under one drifting sky, one enchanted castle plan, one long museum wall
  with its floor along your lowest displays. The gaps between displays are the edge of the world (nothing is laid
  where you can't see it), and frames and borders run along the outline you can actually see.
- Animated water, waves and clouds keep to one clock across displays, so they meet seamlessly at the edges.
- Ink Map's boat now finds its way round islands to reach you (and when it truly can't, it slips out of sight and
  comes back near your cursor), and its islands now carry their names.
- Celestial Atlas, Snowfall and Wind Map span only the displays that show them (they used to treat the whole desk as
  their canvas, so Celestial on one of three displays drew a third of the sky).
- One page runs what moves and the others follow; if its display is covered or paused, another takes over without a
  jump. Settings ▸ Displays ▸ **One world across displays** turns it off (each display draws its own).

### The app, with several displays
- The sidebar shows **what each display is showing** (a spanning world is one row).
- Themes ▸ **Show on**: All displays, or one of them, with what each is showing now; the live preview follows the
  display you pick (its shape, its windows, its notch).
- Displays: a **picker of every theme** for the selected display, and worlds marked on the map.
- The menu bar has a Theme menu for **each display** when you have several, plus All Displays.

### Lighter
- **Calmer frame pacing.** Every theme now draws at a calm 30 frames a second (slow scenes less: Ink Map's ships and
  Garden Plan's gardeners 20, Model Railway and Lava Lamp 24, Meadow's clouds 15) and at 60 only while you're working
  on the wallpaper itself: the pointer over it, a window being dragged. Before, they drew at the display's refresh,
  up to 120 times a second on a ProMotion display. A frame rate picked in Settings still overrides it.
- **The soft scenes draw a little under retina** (Koi Reef, Beach, Meadow, Snowfall, Wind Map, Wind Tunnel at 1.5×,
  Lava Lamp at 1.25×): they look the same, with roughly half the pixels to draw and noticeably less memory. Ink,
  lettering and sprites stay fully sharp.
- Meadow rebuilds its clouds 15 times a second instead of every frame, and skips frames where nothing moved.
- Watching your windows costs less: a lighter read of the window list, a look four times a second when nothing is
  moving (the moment you touch the mouse it's back to every frame), and the pointer sent at 60 Hz.
- Koi Reef's ripples spread at the same pace at any frame rate.

### Steadier
- Tidewall now always keeps a log at `~/Library/Logs/Tidewall.log`, and if it ever crashes it writes down how
  (the error and where it happened), so a problem can be found and fixed.
- Ink Map's island names were never placed (a label-size bug); they are now.
- Gallery hangs the day's new selection at midnight (it used to wait until a window moved).
- Wind Map's clock keeps the right hour across a daylight-saving change.
- A few rare ways to crash closed off: a menu item that rebuilt its own menu mid-click, a display reconfiguring, the
  usage meter on a system call that fails; and pages share one web process again after you change theme.

## [1.0.4]

- **No more blank screens after sleep.** When displays sleep and wake (external monitors reconnecting after you
  unlock, say), macOS can take a page's GPU drawing surface away, and the wallpaper was left showing a plain
  background (on a spanning theme like Celestial Atlas, a navy screen without its stars). Every theme now notices and
  redraws itself, and Tidewall double-checks each display a few seconds after they wake, unlock or change.
- **What's New**: the Tidewall window has a page of release notes, and after an update the menu bar offers
  "What's New in Tidewall …" until you've looked. When an update is waiting, its notes are shown with
  **Restart to Update**.
- A wallpaper page that reloads (after a GPU reset or a crash) gets your windows again straight away; it used to keep
  ignoring them until one moved.
- **Wind Map works with any arrangement of displays.** With a monitor above your laptop, the map reached past the North
  Pole, the weather service refused it, and the wind stayed "offline" (retrying every minute). Requests the service
  rejects outright now wait hours before trying again, and every display reuses a forecast another one fetched.
- **Changing a display while the wallpaper is paused or resting** no longer leaves it black or half drawn (Koi Reef,
  Lava Lamp, Beach, Wind Tunnel, Ink Map): it redraws at the new size, then pauses again.
- **Model Railway and Garden Plan** stay put when a display switches between HiDPI and native, and Railway no longer
  rebuilds its whole board (roads blinking, trains jumping) on every display change. Its memory use no longer grows
  over days, and it does far less work every frame.
- **Lighter while paused**: Beach and Meadow stop drawing entirely (≈5% CPU → 0.2%); Meadow's butterfly settles when
  your cursor has been still for a while, and the kayak naps between strokes.
- **Celestial Atlas** lines up across displays straight after a change and shows the right minute as soon as it resumes.
- **Desktop widgets** are recognised by every theme on every Mac (Celestial and Model Railway only knew the British
  spelling of Notification Centre).
- Smoother over long uptimes: Koi Reef's caustics no longer jump every 34 minutes, Lava Lamp's light shaft no longer
  snaps every 17, and the Wind Tunnel refreshes its simulation clock while you're away (it degraded after ~2 days).
  The Wind Tunnel also no longer leaks GPU memory when the screen resizes as it loads, and retries a failed start.
- Gallery spreads the collection across 3+ displays instead of hanging the same works twice; Koi Reef recovers from a
  bad frame instead of freezing; Railway's steam puffs keep time at any frame rate.

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
