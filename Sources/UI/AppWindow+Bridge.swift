import Cocoa
import ServiceManagement
import WebKit

/// Messages go to the page through `tw.receive(…)` and come back on the "ui" handler, or "host" from the preview's theme.
extension AppWindow {
  func js(_ json: String) { web?.evaluateJavaScript("window.tw&&tw.receive(\(json));null", completionHandler: nil) }

  func showPage(_ page: String) { js("{\"t\":\"show\",\"page\":\"\(page)\"}") }

  private func send(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message), let json = String(data: data, encoding: .utf8) else {
      return
    }
    js(json)
  }

  private func toast(_ s: String) { send(["t": "toast", "s": s]) }

  func pushState() {
    guard app != nil, web != nil else { return }
    sendState(displays: fakeWorld.isEmpty ? realDisplays() : pretendDisplays())
  }

  func pushDesktop(icons: Bool = false) {
    guard web != nil else { return }
    js("{\"t\":\"desktop\",\"d\":\(desktopJSON())\(icons ? ",\"icons\":1" : "")}")
  }

  /// What the wallpaper costs, and apart from it what this window costs while it's open.
  func pushUsage() {
    guard let u = app?.usage.sample() else { return }
    let ui = pid_t(web.map(webPid) ?? -1)
    let windowCPU = u.cpuBy[ui] ?? 0, windowMem = u.memBy[ui] ?? 0
    js(String(format: "{\"t\":\"usage\",\"cpu\":%.2f,\"gpu\":%.2f,\"mem\":%.1f,\"winCpu\":%.2f,\"winMem\":%.1f}",
              max(0, u.cpu - windowCPU), u.gpu, max(0, u.memMB - windowMem), windowCPU, windowMem))
  }

  private func sendState(displays: [[String: Any]]) {
    guard let app else { return }
    var variants: [String: String] = [:]
    for (t, _) in Cfg.themes {
      if let v = Cfg.variant(t) { variants[t] = v }
    }
    send(["t": "state", "current": Cfg.theme, "displays": displays, "variants": variants, "seed": Cfg.seed,
          "version": Cfg.version, "siteQuery": Cfg.siteQuery, "spanThemes": Array(Cfg.spanThemes),
          "settings": settings(of: app),
          "update": app.updater.status, "newNotes": Cfg.hasNewNotes, "notesSeen": Cfg.notesSeen ?? ""])
  }

  private func settings(of app: App) -> [String: Any] {
    ["spanWorlds": Cfg.spanWorlds, "login": LoginItem.enabled, "loginBlocked": LoginItem.blocked,
     "restWhenIdle": Cfg.restWhenIdle, "paused": app.userPaused, "fps": Cfg.fps, "tier": Cfg.tier, "margin": Cfg.margin,
     "autoUpdate": Cfg.autoUpdate, "deskIcons": Cfg.deskIcons, "deskIconsState": app.deskIcons.state.rawValue,
     "reactWindows": Cfg.reactWindows, "reactStage": Cfg.reactStage, "reactWidgets": Cfg.reactWidgets,
     "reactCursor": Cfg.reactCursor, "idleMinutes": Cfg.idleMinutes, "battery": Cfg.battery,
     "onBattery": app.power.onBattery, "lowPower": app.power.lowPower]
  }

  private func realDisplays() -> [[String: Any]] {
    NSScreen.screens.map { s -> [String: Any] in
      let f = s.cgFrame, id = s.displayID
      return ["id": Int(id), "name": s.localizedName, "x": f.minX, "y": f.minY, "w": f.width, "h": f.height,
              "theme": Cfg.theme(for: id), "own": hasOwnTheme(id), "main": s == NSScreen.screens.first,
              "world": Cfg.world(of: id).map { Int($0.displayID) }]
    }
  }

  private func pretendDisplays() -> [[String: Any]] {
    let ids = fakeWorld.keys.sorted()
    let main = ids.first { fakeWorld[$0]?.origin == .zero }
    return ids.map { id -> [String: Any] in
      let f = fakeWorld[id]!, t = Cfg.theme(for: id)
      let spans = Cfg.spanWorlds && Cfg.spanThemes.contains(t)
      let world = spans ? ids.filter { Cfg.theme(for: $0) == t }.map { Int($0) } : [Int(id)]
      return ["id": Int(id), "name": id == main ? "Built-in Retina Display" : "Monitor \(id - 1000)",
              "x": f.minX, "y": f.minY, "w": f.width, "h": f.height, "theme": t,
              "own": hasOwnTheme(id), "main": id == main, "world": world]
    }
  }

  private func hasOwnTheme(_ id: CGDirectDisplayID) -> Bool { Cfg.d.string(forKey: "theme.display.\(id)") != nil }

  /// A display (the main one by default) and what's on it now, so the preview shows your own desktop.
  private func desktopJSON(display: CGDirectDisplayID? = nil) -> String {
    guard let app, let screen = NSScreen.screens.first(where: { $0.displayID == display }) ?? NSScreen.screens.first else {
      return "null"
    }
    let fake = display.flatMap { fakeWorld[$0] }
    let frame = fake ?? screen.cgFrame
    let hasNotch = screen.safeAreaInsets.top > 0
    let desktop: [String: Any] = ["w": frame.width, "h": frame.height,
                                  "windows": windows(of: app, on: frame), "icons": desktopIcons(on: frame),
                                  "display": Int(fake != nil ? display! : screen.displayID),
                                  "notch": fake.map { $0.origin == .zero && hasNotch } ?? hasNotch]
    return (try? JSONSerialization.data(withJSONObject: desktop)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
  }

  /// The windows on this frame, in its coordinates. Left out: Tidewall's own, and Stage Manager's app-icon badges.
  private func windows(of app: App, on frame: CGRect) -> [[String: Any]] {
    var windows: [[String: Any]] = []
    for (i, r) in app.lastRects.enumerated() where r.intersects(frame) {
      let owner = i < app.lastOwners.count ? app.lastOwners[i] : ""
      if ["Tidewall", "tidewall", "WindowManager", "Dock"].contains(owner) { continue }
      let widget = Tracker.widgetRects.contains("\(r)")
        || owner == "Notification Centre" || owner == "Notification Center" || owner == "WidgetKit Simulator"
      windows.append(["x": r.minX - frame.minX, "y": r.minY - frame.minY, "w": r.width, "h": r.height, "name": owner,
                      "sm": Tracker.stageRects.contains("\(r)"), "widget": widget])
    }
    return windows
  }

  /// Your desktop icons on this frame: whole, the images alone, and the groups.
  private func desktopIcons(on frame: CGRect) -> [String: Any] {
    let local = { (r: CGRect) -> [CGFloat] in [r.minX - frame.minX, r.minY - frame.minY, r.width, r.height] }
    guard let di = DeskIcons.shared else { return ["r": [[CGFloat]](), "i": [[CGFloat]](), "c": [[CGFloat]]()] }
    let on = di.icons.indices.filter { di.icons[$0].intersects(frame) }
    return ["r": on.map { local(di.icons[$0]) },
            "i": on.compactMap { $0 < di.images.count ? local(di.images[$0]) : nil },
            "c": di.clusters.filter { $0.intersects(frame) }.map(local)]
  }

  func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
    if m.name == "host" {
      let s = "\(m.body)"
      if s.hasPrefix("JSERR") || s.hasPrefix("NOTE") { log("[preview] \(s)") }
      return
    }
    guard m.frameInfo.isMainFrame, let app, let str = m.body as? String, let data = str.data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let t = o["t"] as? String else { return }
    switch t {
    case "hello":
      greet()
    case "desktop":
      let display = (o["display"] as? Int).flatMap { CGDirectDisplayID(exactly: $0) }
      js("{\"t\":\"desktop\",\"d\":\(desktopJSON(display: display))}")
    case "report":
      ProblemReport.send()
      toast("The end of Tidewall’s log is on your clipboard: paste it into the issue if you’re happy to share it.")
    case "openAutomation":
      NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    case "open":
      if let s = o["url"] as? String, let url = URL(string: s), ["https", "http"].contains(url.scheme ?? "") {
        NSWorkspace.shared.open(url)
      }
    case "log":
      log("[ui] \(o["s"] as? String ?? "")")
    case "quit":
      NSApp.terminate(nil)
    default:
      guard handleChange(t, o, app: app) else { return log("[ui] unknown message \(t)") }
      pushState()
      app.statusMenu?.rebuild()
    }
  }

  /// The page has loaded: everything it shows, and the page it was opened on.
  private func greet() {
    pushState()
    pushUsage()
    js("{\"t\":\"desktop\",\"d\":\(desktopJSON())}")
    send(["t": "notes", "md": Cfg.changelog])
    if let p = pendingPage {
      pendingPage = nil
      showPage(p)
    }
  }

  /// Messages that change something; the page and the menu then get the new state. False for a message it doesn't know.
  private func handleChange(_ t: String, _ o: [String: Any], app: App) -> Bool {
    switch t {
    case "notesSeen":
      Cfg.notesSeen = Cfg.version
      app.statusMenu?.rebuild()
    case "apply":
      if let id = o["theme"] as? String, isTheme(id) {
        Cfg.clearDisplayThemes()
        Cfg.theme = id
        app.reloadAll()
      }
    case "applyDisplay":
      applyDisplayTheme(o, app: app)
    case "variant":
      if let theme = o["theme"] as? String, let v = o["id"] as? String {
        Cfg.setVariant(theme, v)
        for s in NSScreen.screens where Cfg.theme(for: s.displayID) == theme { app.reloadWall(s.displayID) }
      }
    case "set":
      set(o["key"] as? String ?? "", to: o["value"], app: app)
    case "reload":
      app.reloadAll()
    case "checkUpdate":
      app.updater.check(manual: false, fromWindow: true)
    case "installUpdate":
      app.updater.install()
    default:
      return false
    }
    return true
  }

  private func isTheme(_ id: String?) -> Bool { Cfg.themes.contains { $0.0 == id } }

  private func applyDisplayTheme(_ o: [String: Any], app: App) {
    let theme = o["theme"] as? String
    guard theme == nil || isTheme(theme) else { return log("[ui] no theme called \(theme ?? "")") }
    guard let n = o["display"] as? Int, let id = CGDirectDisplayID(exactly: n),
          NSScreen.screens.contains(where: { $0.displayID == id }) || fakeWorld[id] != nil else {
      toast("That display isn't connected any more.")
      return
    }
    Cfg.setTheme(theme, for: id)
    app.reloadWall(id)
    app.resendDesks()
  }

  private func set(_ key: String, to v: Any?, app: App) {
    switch key {
    case "login":
      setOpenAtLogin(v as? Bool ?? false)
    case "restWhenIdle":
      Cfg.idleMinutes = (v as? Bool ?? true) ? Cfg.idleLast : 0
    case "spanWorlds":
      Cfg.spanWorlds = v as? Bool ?? true
      app.resendDesks()
      app.tracker.forceResend()   // each page gets its new world's windows
    case "deskIcons":
      Cfg.deskIcons = v as? Bool ?? false
      app.deskIcons.start()   // turning it on is when macOS asks for permission, once
    case "autoUpdate":
      Cfg.autoUpdate = v as? Bool ?? true
      if Cfg.autoUpdate { app.updater.check(manual: false) }
    case "paused":
      app.userPaused = v as? Bool ?? false
      app.dispatch(live: false)
    case "fps":
      Cfg.fps = (v as? NSNumber)?.doubleValue ?? 0
      app.reloadAll()
    case "tier":
      Cfg.tier = (v as? NSNumber)?.intValue ?? 1
      app.reloadAll()
    case "margin":
      Cfg.margin = (v as? NSNumber)?.doubleValue ?? 140
      app.tracker.forceResend()
      app.dispatch(live: false)
    case "reactWindows", "reactStage", "reactWidgets":
      let on = v as? Bool ?? true
      switch key {
      case "reactWindows": Cfg.reactWindows = on
      case "reactStage": Cfg.reactStage = on
      default: Cfg.reactWidgets = on
      }
      app.tracker.forceResend()
      app.dispatch(live: false)
    case "reactCursor":
      Cfg.reactCursor = v as? Bool ?? true
      if !Cfg.reactCursor {
        for w in app.walls.values { w.send("{\"t\":\"cursorOff\"}") }
      }
    case "idleMinutes":
      Cfg.idleMinutes = (v as? NSNumber)?.doubleValue ?? 3
    case "battery":
      Cfg.battery = (v as? NSNumber)?.intValue ?? 0
      app.checkPower()
    default:
      break
    }
  }

  private func setOpenAtLogin(_ on: Bool) {
    if args.contains("--ui-only") {
      toast("Development window: the login item isn't changed.")
    } else if LoginItem.blocked && on {
      SMAppService.openSystemSettingsLoginItems()
    } else if let why = LoginItem.set(on) {
      toast(why)
    }
  }
}
