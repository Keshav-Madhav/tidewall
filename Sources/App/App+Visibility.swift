import Cocoa

/// Deciding, on every window change, what each page should do: follow the windows, rest, or be let go.
///
/// - A page rests (keeps its last frame, draws nothing) while paused, asleep, locked, idle, paused on battery, or when
///   nothing of it shows but through the menu bar and Dock.
/// - A screen covered by a full-screen app for 15 s has its page closed; one covered but for its menu bar and Dock
///   (a maximized window) for 30 s swaps its page for a still picture of it.
/// - Away for a while (paused, locked or asleep 90 s, idle at the desk 10 minutes), every page is let go, all of its
///   memory with it, and a still picture stays on each screen until you're back.
extension App {
  func dispatch(live: Bool) {
    if !benchMode && !live { updateCoveredScreens() }
    scheduleCoverCheck()
    let resting = userPaused || asleep || idleRest
    Tracker.idle = resting || power.paused
    if resting { scheduleRelease() } else { cancelRelease() }

    let hidden = NSScreen.screens.allSatisfy { dormant.contains($0.displayID) || coveredSince[$0.displayID] != nil }
    if hidden != Tracker.allHidden {
      Tracker.allHidden = hidden
      log(hidden ? "everything covered: idling" : "something visible again")
    }

    let now = ProcessInfo.processInfo.systemUptime
    for w in walls.values {
      let world = Cfg.spanThemes.contains(Cfg.theme(for: w.screenID)) ? worldFrames(for: w.screenID) : [w.cgFrame]
      let shown = lastRects.indices.filter { i in world.contains { lastRects[i].intersects($0) } && reacts(i) }
      w.realRects = lastRects.filter { $0.intersects(w.cgFrame) }
      w.usable = benchMode ? nil : usableFrame(w)
      // never pause while windows move: a sliver of the scene may still show and must keep up
      let onlyBehindBars = !live && uncoveredArea(benchMode ? w.cgFrame : usableFrame(w), w.realRects) < 1
      let pause = resting || power.paused || onlyBehindBars
      if !pause && w.ready && w.seenSince == nil { w.seenSince = now }
      w.update(rects: shown.map { lastRects[$0] }, owners: shown.map(owner), live: live, pause: pause)
    }
  }

  private func owner(_ i: Int) -> String { i < lastOwners.count ? lastOwners[i] : "" }

  /// Whether the scene reshapes around this window (Settings ▸ The wallpaper reacts to).
  private func reacts(_ i: Int) -> Bool {
    let key = "\(lastRects[i])"
    if Tracker.stageRects.contains(key) { return Cfg.reactStage }
    if Tracker.widgetRects.contains(key) || ["Notification Centre", "Notification Center", "WidgetKit Simulator"].contains(owner(i)) {
      return Cfg.reactWidgets
    }
    return Cfg.reactWindows
  }

  /// The part of a display windows can use: below the menu bar, beside the Dock.
  func usableFrame(_ s: NSScreen) -> CGRect {
    let h = NSScreen.screens.first?.frame.height ?? s.frame.maxY, v = s.visibleFrame
    return CGRect(x: v.minX, y: h - v.maxY, width: v.width, height: v.height)
  }

  func usableFrame(_ w: Wallpaper) -> CGRect {
    NSScreen.screens.first { $0.displayID == w.screenID }.map(usableFrame) ?? w.cgFrame
  }

  // MARK: covered screens

  private func updateCoveredScreens() {
    let now = ProcessInfo.processInfo.systemUptime
    for s in NSScreen.screens {
      let id = s.displayID
      let full = uncoveredArea(s.cgFrame, lastRects) < 1
      let covered = full || uncoveredArea(usableFrame(s), lastRects) < 1
      if covered {
        if coveredSince[id] == nil {
          coveredSince[id] = now
          if !full, let w = walls[id] { keepStill(id, w) }
        }
      } else {
        coveredSince[id] = nil
        pendingStills[id] = nil
      }

      if covered, let since = coveredSince[id], now - since > (full ? 15 : 30), let w = walls[id] {
        if full {
          w.close()
          walls[id] = nil
          dormant.insert(id)
          log("screen \(id) fully covered: released its page")
        } else if let img = pendingStills[id] ?? thumbnail(Cfg.theme(for: id)) {
          // covered since it opened, WebKit never drew it: the theme's thumbnail reads the same through a menu bar
          releaseToStill(id, w, img)
          log("screen \(id) covered but for its menu bar: a still picture, page released")
        }
      } else if !covered, dormant.contains(id), !releasedAway {
        dormant.remove(id)
        buildWalls()
        log("screen \(id) uncovered: page restored")
      }
    }
  }

  /// Covered screens are only let go after a while, and nothing else may call dispatch meanwhile: look again then.
  private func scheduleCoverCheck() {
    guard coverTimer == nil, !coveredSince.isEmpty else { return }
    coverTimer = Timer.scheduledTimer(withTimeInterval: 16, repeats: false) { [weak self] _ in
      self?.coverTimer = nil
      self?.dispatch(live: false)
    }
  }

  private func thumbnail(_ theme: String) -> NSImage? {
    NSImage(contentsOf: themesRoot.appendingPathComponent("ui/thumbs/\(theme).jpg"))
  }

  /// The moment a display is covered but for its menu bar and Dock: a picture of its page as last seen. A page covered
  /// all along has nothing worth keeping (WebKit doesn't render a hidden window).
  private func keepStill(_ id: CGDirectDisplayID, _ w: Wallpaper) {
    guard let t = w.seenSince, ProcessInfo.processInfo.systemUptime - t > 5 else { return }
    w.web.takeSnapshot(with: nil) { [weak self] img, _ in
      if let self, let img, coveredSince[id] != nil { pendingStills[id] = img }
    }
  }

  private func releaseToStill(_ id: CGDirectDisplayID, _ w: Wallpaper, _ img: NSImage) {
    walls[id] = nil
    dormant.insert(id)
    pendingStills[id] = nil
    stills[id]?.close()
    stills[id] = StillWall(frame: w.window.frame, image: img)
    w.close()
  }

  // MARK: away

  private func scheduleRelease() {
    guard awayTimer == nil, !walls.isEmpty else { return }
    let wait = userPaused || asleep ? Double(argValue("--away") ?? "90") ?? 90 : Double(argValue("--idleaway") ?? "600") ?? 600
    awayTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
      guard let self, userPaused || asleep || idleRest else { return }
      releaseToStills()
    }
  }

  private func cancelRelease() {
    awayTimer?.invalidate()
    awayTimer = nil
    if releasedAway {
      releasedAway = false
      log("back: rebuilding pages")
      buildWalls()
    }
  }

  /// Every page let go, each screen left showing its last frame as a still picture.
  private func releaseToStills() {
    let released = walls
    walls = [:]
    releasedAway = true
    for (id, w) in released {
      w.web.takeSnapshot(with: nil) { [weak self] img, _ in
        defer { w.close() }
        guard let self, let img, releasedAway else { return }
        stills[id]?.close()
        stills[id] = StillWall(frame: w.window.frame, image: img)
        #if TIDEWALL_DEV
        if let path = argValue("--stilldump") { img.writePNG(to: path) }
        #endif
      }
    }
    log("away: released every page (still pictures on show)")
  }

  /// While the pages are let go, a new theme or setting must still show: bring them back (each still stays up until its
  /// new page has drawn) and let the away timer let them go again later.
  func comeBackIfAway() {
    guard releasedAway else { return }
    releasedAway = false
    awayTimer?.invalidate()
    awayTimer = nil
    DispatchQueue.main.async { [weak self] in self?.dispatch(live: false) }
  }
}
