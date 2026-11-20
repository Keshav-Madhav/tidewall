import Cocoa

/// Creating, resizing, reloading and closing the wallpapers as displays come and go.
extension App {
  func buildWalls() {
    if args.contains("--ui-only") { return }
    if !fakeWorld.isEmpty, let screen = NSScreen.screens.first {
      for (id, frame) in fakeWorld where walls[id] == nil { walls[id] = Wallpaper(screen: screen, fakeID: id, fakeFrame: frame) }
      tracker.forceResend()
      return
    }
    let ids = Set(NSScreen.screens.map { $0.displayID })
    for (id, still) in stills where !ids.contains(id) {   // a display unplugged while away
      still.close()
      stills[id] = nil
    }
    if releasedAway { return }   // the pages come back when you do
    for (id, w) in walls where !ids.contains(id) {
      w.close()
      walls[id] = nil
    }
    for s in NSScreen.screens where (!benchMode || s == NSScreen.screens.first) && !dormant.contains(s.displayID) {
      if let w = walls[s.displayID] {
        let resized = w.window.frame.size != s.frame.size
        w.cgFrame = s.cgFrame
        w.window.setFrame(s.frame, display: true)
        w.sendDesk()
        if resized { w.redrawIfPaused() }
      } else {
        openWall(on: s)
      }
    }
    tracker.forceResend()
  }

  /// A new page for a display. If a still picture is on show there, the page opens hidden behind it and takes over
  /// once it has drawn (or after 8 s, so a stale still never stays up).
  private func openWall(on s: NSScreen) {
    let id = s.displayID, still = stills[id]
    let w = Wallpaper(screen: s, hidden: still != nil)
    walls[id] = w
    guard let still else { return }
    let dropStill = { [weak self] in
      still.close()
      if self?.stills[id] === still { self?.stills[id] = nil }
    }
    w.onShown = dropStill
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
      if self?.stills[id] === still {
        w.window.alphaValue = 1
        dropStill()
      }
    }
  }

  func reloadAll() {
    walls.values.forEach { $0.close() }
    walls = [:]
    comeBackIfAway()
    buildWalls()
  }

  func reloadWall(_ id: CGDirectDisplayID) {
    walls[id]?.close()
    walls[id] = nil
    comeBackIfAway()
    buildWalls()
  }

  /// A theme changed somewhere: worlds may have grown or shrunk, so every page hears its desk again.
  func resendDesks() {
    for w in walls.values {
      w.sendDesk()
      w.sendDeskIcons()
    }
  }

  func sendDeskIcons() {
    walls.values.forEach { $0.sendDeskIcons() }
    appWindow.pushState()
    appWindow.pushDesktop(icons: true)
  }

  /// A few seconds after the displays wake (external monitors take a moment), reload any page left without its WebGL
  /// context. Pages usually notice by themselves; this is the safety net.
  func checkGPUContexts(after delay: Double = 4) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self, !releasedAway else { return }
      for (id, w) in walls {
        w.web.evaluateJavaScript("!!(window.__twGLLost && window.__twGLLost())") { [weak self] r, _ in
          guard (r as? Bool) == true else { return }
          log("[\(id)] lost its GPU context: reloading")
          self?.reloadWall(id)
        }
      }
    }
  }

  /// Wind Tunnel with no model chosen draws your desktop icons while there are some, and its default model when there
  /// are none. When that flips, reopen it once things settle.
  func retuneTunnel() {
    tunnelTimer?.invalidate()
    tunnelTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
      guard let self else { return }
      let v = Cfg.variant("tunnel")
      let stale = walls.filter { Cfg.theme(for: $0.key) == "tunnel" && $0.value.loadedVariant != v }.map(\.key)
      for id in stale { reloadWall(id) }
      if !stale.isEmpty { appWindow.pushState() }
    }
  }
}
