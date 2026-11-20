#if TIDEWALL_DEV
import Cocoa
import WebKit

/// Launch flags for testing (development builds only). tools/regress.sh, tools/smooth.sh and the promo scripts drive
/// the app through these; `--bench` itself is in Bench.swift.
extension App {
  /// --ui-only: the app window alone, no wallpapers, to work on the interface.
  func runWindowOnly() {
    tracker.onUpdate = { [weak self] rects, _ in
      self?.lastRects = rects
      self?.lastOwners = self?.tracker.owners ?? []
    }
    tracker.start()
    buildMainMenu { [weak self] in self?.appWindow.show(page: "about") }
    appWindow.show()
    after("--closetest") { $0.appWindow.window?.performClose(nil) }   // is everything freed?
    if args.contains("--demo") { after(2) { $0.appWindow.js("{\"t\":\"demo\"}") } }
    if let mode = argValue("--mode") {
      after(2.5) { $0.appWindow.js("{\"t\":\"mode\",\"m\":\"\(mode == "sample" ? "sample" : "mine")\"}") }
    }
    if let theme = argValue("--select") { after(1.5) { $0.appWindow.js("{\"t\":\"select\",\"id\":\"\(theme)\"}") } }
    if let page = argValue("--page") { after(1.5) { $0.appWindow.show(page: page) } }
    if args.contains("--hittest") { after(2) { $0.logTitlebarHits(); NSApp.terminate(nil) } }
  }

  /// --fakescreens LAYOUT: pretend displays around the real main one, each its own page in this app.
  func pretendDisplays() {
    guard benchMode, let layout = argValue("--fakescreens"),
          let b = NSScreen.screens.first.map({ CGRect(origin: .zero, size: $0.frame.size) }) else { return }
    let hd = CGSize(width: 1920, height: 1080)
    let R = { (x: CGFloat, y: CGFloat, size: CGSize) in CGRect(origin: CGPoint(x: x, y: y), size: size) }
    switch layout {
    case "row":       // one each side, a little higher
      fakeWorld = [1001: R(-1920, b.minY - 98, hd), 1002: b, 1003: R(b.maxX, b.minY - 98, hd)]
    case "two":       // one on the left, bottoms level
      fakeWorld = [1001: R(-1920, b.maxY - 1080, hd), 1002: b]
    case "portrait":  // one on its side, to the right
      fakeWorld = [1001: b, 1002: R(b.maxX, b.minY - 420, CGSize(width: 1080, height: 1920))]
    case "big":       // a 1440p one above, overhanging
      fakeWorld = [1001: R(b.minX - 300, b.minY - 1440, CGSize(width: 2560, height: 1440)), 1002: b]
    default:          // "stacked", "above2": two side by side above the laptop, meeting over it
      fakeWorld = [1001: R(b.minX - 1533, b.minY - 1080, hd), 1002: R(b.minX + 387, b.minY - 1080, hd), 1003: b]
    }
    // the monitors are 1× displays (--fakeretina: 2×, like the laptop)
    for (id, f) in fakeWorld where f != b { fakeScale[id] = args.contains("--fakeretina") ? 2 : 1 }
  }

  /// --fakeicons N: a column of N desktop icons down the main display's right edge.
  func pretendDesktopIcons() {
    guard benchMode, let n = argValue("--fakeicons").flatMap(Int.init) else { return }
    let main = fakeWorld.first { $0.value.origin == .zero }?.value
      ?? NSScreen.screens.first.map { CGRect(origin: .zero, size: $0.frame.size) } ?? .zero
    let g = DeskIcons.geometry(), step = g.icon + g.text * 2.6 + 30, rows = max(1, Int((main.height - 60) / step))
    deskIcons.fake = (0..<n).map { i in
      let c = CGPoint(x: main.maxX - 66 - CGFloat(i / rows) * 108, y: main.minY + 73 + CGFloat(i % rows) * step)
      return (DeskIcons.box(c, g), DeskIcons.image(c, g))
    }
  }

  func startDevHooks() {
    after("--lose-gl-at") { app in
      log("bench: losing every WebGL context")
      app.evalEverywhere("document.querySelectorAll('canvas').forEach(c => { const g = c.getContext('webgl2') || c.getContext('webgl'); const x = g && g.getExtension('WEBGL_lose_context'); x && x.loseContext(); }); null")
    }
    for flag in ["--resize-at", "--resize-raw-at"] { after(flag) { $0.shrinkScreens(flag) } }
    if let js = argValue("--eval-each") {   // ask every page the same question every --eval-every seconds
      let every = Double(argValue("--eval-every") ?? "4") ?? 4
      Timer.scheduledTimer(withTimeInterval: every, repeats: true) { [unowned self] _ in
        ask(js) { id, answer, error in log("eval [\(id)] \(answer ?? "error: \(error?.localizedDescription ?? "?")")") }
      }
    }
    if let t = argValue("--cycle").flatMap(Double.init) {   // every theme in turn, t seconds each (a memory soak)
      var i = 0
      Timer.scheduledTimer(withTimeInterval: t, repeats: true) { [unowned self] _ in
        i += 1
        let id = Cfg.themes[i % Cfg.themes.count].0
        Cfg.themeOverride = id
        log("bench: theme \(i) \(id)")
        reloadAll()
      }
    }
    after("--reload-at") { log("bench: reloadAll"); $0.reloadAll() }
    if benchMode, let path = argValue("--uisteps") { walkTheWindow(path) }
    if benchMode, !fakeWorld.isEmpty { after("--unplug-at") { $0.unplugPretendDisplay() } }
    if benchMode {
      after("--crashtest") { _ in   // a real bad-pointer crash, for the crash log to catch
        log("crashtest: writing through a bad pointer")
        UnsafeMutablePointer<Int>(bitPattern: 0x18)!.pointee = 1
      }
    }
    if benchMode, let t = argValue("--uistress").flatMap(Double.init) { stressTheWindow(every: t) }
    if let a = argValue("--testpause").flatMap(Double.init) {   // pause at a, resume 8 s later
      after(a) { $0.userPaused = true; $0.dispatch(live: false) }
      after(a + 8) { $0.userPaused = false; $0.dispatch(live: false) }
    }
    if args.contains("--usage") {   // what the menu would show, every 2 s
      _ = usage.sample()
      Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
        guard let s = self?.usage.sample() else { return }
        log(String(format: "USAGE cpu=%.1f%% gpu=%.1f%% mem=%.0fMB procs=%d", s.cpu, s.gpu, s.memMB, s.procs))
      }
    }
  }

  // MARK: helpers

  private func after(_ seconds: Double, _ f: @escaping (App) -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [unowned self] in f(self) }
  }

  /// Runs f the number of seconds a flag gives, if it was passed.
  private func after(_ flag: String, _ f: @escaping (App) -> Void) {
    if let t = argValue(flag).flatMap(Double.init) { after(t, f) }
  }

  private func evalEverywhere(_ js: String) {
    for w in walls.values { w.web.evaluateJavaScript(js, completionHandler: nil) }
  }

  /// Asks every page, in display order, the body of a JavaScript function; answers come back as strings.
  private func ask(_ body: String, _ answer: @escaping (CGDirectDisplayID, String?, Error?) -> Void) {
    for (id, w) in walls.sorted(by: { $0.key < $1.key }) {
      w.web.evaluateJavaScript("String((() => { \(body) })())") { r, e in answer(id, r as? String, e) }
    }
  }

  /// Settings a test changes are put back when it ends, so the next one starts from the same place.
  private func restoreSettingsOnQuit() {
    let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    let saved = Cfg.d.persistentDomain(forName: domain) ?? [:]
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
      Cfg.d.setPersistentDomain(saved, forName: domain)
      Cfg.d.synchronize()
    }
  }

  /// --resize-at / --resize-raw-at: every wall's window loses 200 pt of width, as if the screen changed size (while
  /// paused, say); 0.6 s on, the real path rebuilds from the screen, the raw one just restores the frame.
  private func shrinkScreens(_ flag: String) {
    for w in walls.values {
      var f = w.window.frame
      f.size.width -= 200
      w.window.setFrame(f, display: true)
    }
    log("bench: resized (\(flag))")
    after(0.6) { app in
      if flag == "--resize-at" { return app.buildWalls() }
      for (id, w) in app.walls {
        if let s = NSScreen.screens.first(where: { $0.displayID == id }) { w.window.setFrame(s.frame, display: true) }
      }
    }
  }

  /// --unplug-at T [--unplug ID]: a pretend display goes away mid-run, its page with it.
  private func unplugPretendDisplay() {
    let id = CGDirectDisplayID(argValue("--unplug") ?? "1001") ?? 1001
    log("bench: unplugging \(id)")
    fakeWorld[id] = nil
    fakeScale[id] = nil
    walls[id]?.close()
    walls[id] = nil
    resendDesks()
    tracker.forceResend()
    appWindow.pushState()
  }

  /// --uisteps FILE: a scripted walk through the app window. Each step: at (s), ui (JavaScript run in the window), shot
  /// (the window saved as <shot>.png), pages (JavaScript asked of every page, logged as "PAGE <id> <label> <answer>").
  private func walkTheWindow(_ path: String) {
    guard let d = FileManager.default.contents(atPath: path),
          let steps = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return }
    restoreSettingsOnQuit()
    appWindow.show()
    for step in steps {
      after((step["at"] as? NSNumber)?.doubleValue ?? 0) { app in
        if let js = step["ui"] as? String {
          app.appWindow.web?.evaluateJavaScript(js) { r, e in
            if let e { log("UI error: \(e.localizedDescription)") } else if let r { log("UI \(r)") }
          }
        }
        if let shot = step["shot"] as? String, let w = app.appWindow.web {
          w.takeSnapshot(with: nil) { img, _ in
            if img?.writePNG(to: shot + ".png") == true { log("SHOT \(shot)") }
          }
        }
        if let js = step["pages"] as? String {
          app.ask(js) { id, answer, _ in log("PAGE \(id) \(step["label"] as? String ?? "") \(answer ?? "?")") }
        }
      }
    }
  }

  /// --uistress T: what a tester does in the window and the menu, as fast as a click every T seconds.
  private func stressTheWindow(every t: Double) {
    restoreSettingsOnQuit()
    appWindow.show()
    var n = 0
    Timer.scheduledTimer(withTimeInterval: t, repeats: true) { [unowned self] _ in
      n += 1
      if n % 17 == 0 {
        log("uistress \(n): close and reopen the window")
        appWindow.window?.performClose(nil)
        after(0.8) { $0.appWindow.show() }
      } else if n % 3 == 0, let menu = statusMenu?.menu {
        clickRandomItem(in: menu, n)
      } else {
        appWindow.web?.evaluateJavaScript(Self.randomUIAction) { r, e in
          log("uistress \(n): \(r as? String ?? "error \(e?.localizedDescription ?? "?")")")
        }
      }
    }
  }

  private func clickRandomItem(in menu: NSMenu, _ n: Int) {
    let skip = ["Quit", "Open", "Check", "What", "Restart", "Download", "About", "Report"]
    var items: [(NSMenu, Int, String)] = []
    func walk(_ m: NSMenu) {
      for (i, it) in m.items.enumerated() {
        if let sub = it.submenu { walk(sub) }
        else if it.isEnabled, it.action != nil, !skip.contains(where: { it.title.hasPrefix($0) }) { items.append((m, i, it.title)) }
      }
    }
    walk(menu)
    guard let (m, i, title) = items.randomElement() else { return }
    log("uistress \(n): menu \(title)")
    m.performActionForItem(at: i)
  }

  private static let randomUIAction = """
    (() => { const T = ['railway','garden','estate','gallery','inkmap','celestial','snow','lava','wind','reef','tunnel','meadow','beach'];
      const r = Math.random(), th = T[Math.floor(Math.random() * T.length)], ids = (S.displays || []).map(d => d.id);
      let a;
      if (r < .3) a = { t: 'apply', theme: th };
      else if (r < .4) a = { t: 'applyDisplay', display: ids[Math.floor(Math.random() * ids.length)] || 1, theme: Math.random() < .2 ? null : th };
      else if (r < .5) a = { t: 'set', key: 'spanWorlds', value: Math.random() < .5 };
      else if (r < .6) a = { t: 'set', key: 'fps', value: [0, 30, 60][Math.floor(Math.random() * 3)] };
      else if (r < .68) a = { t: 'set', key: 'paused', value: Math.random() < .3 };
      else if (r < .76) a = { t: 'set', key: 'margin', value: Math.round(80 + Math.random() * 120) };
      else if (r < .84) a = { t: 'variant', theme: Math.random() < .5 ? 'lava' : 'wind', id: Math.random() < .5 ? 'blue' : 'IND' };
      else if (r < .9) a = Math.random() < .5 ? { t: 'set', key: 'idleMinutes', value: [0, 1, 3, 10][Math.floor(Math.random() * 4)] } : { t: 'set', key: ['reactWindows', 'reactStage', 'reactWidgets', 'reactCursor'][Math.floor(Math.random() * 4)], value: Math.random() < .5 };
      else if (r < .95) a = { t: 'reload' };
      else a = { t: 'desktop', display: ids[0] };
      send(a); return JSON.stringify(a); })()
    """

  /// --hittest: which view a click lands on across the window's top (the traffic lights must stay the system's).
  private func logTitlebarHits() {
    guard let w = appWindow.window, let frame = w.contentView?.superview else { return }
    let h = w.frame.height
    let viewName = { (v: NSView?) in v.map { String(describing: type(of: $0)) } ?? "nothing" }
    for (b, name) in [(NSWindow.ButtonType.closeButton, "close"), (.miniaturizeButton, "minimise"), (.zoomButton, "zoom")] {
      guard let btn = w.standardWindowButton(b), let sv = btn.superview else { continue }
      let c = frame.convert(sv.convert(NSPoint(x: btn.frame.midX, y: btn.frame.midY), to: nil), from: nil)
      log("hit \(name) button: \(viewName(frame.hitTest(c)))")
    }
    let spots: [(String, CGFloat, CGFloat)] = [("left of the buttons", 4, h - 14), ("top strip, middle", 600, h - 14),
      ("top strip, right", w.frame.width - 60, h - 10), ("sidebar top", 110, h - 40), ("main below strip", 600, h - 40), ("sidebar nav", 110, h - 120)]
    for (name, x, y) in spots {
      let v = frame.hitTest(frame.convert(NSPoint(x: x, y: y), from: nil))
      log("hit \(name): \(viewName(v))\(v?.mouseDownCanMoveWindow == true ? " (moves window)" : "")")
    }
  }
}
#endif
