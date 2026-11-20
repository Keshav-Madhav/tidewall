import Cocoa
import ServiceManagement

/// The menu-bar item: what's new, updates, a live CPU / GPU / memory readout, the theme per display, and the switches.
final class StatusMenu: NSObject, NSMenuDelegate {
  private unowned let app: App
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private var usageTimer: Timer?
  private static let usageTag = 900
  private let mono = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

  var menu: NSMenu? { item.menu }

  init(app: App) {
    self.app = app
    super.init()
    item.button?.image = menuGlyph()
    item.button?.toolTip = "Tidewall"
  }

  func rebuild() {
    let m = NSMenu()
    m.delegate = self
    addNotices(to: m)
    addUsageReadout(to: m)
    m.addItem(.separator())
    let open = ClosureItem("Open Tidewall…") { [weak self] in self?.app.appWindow.show() }
    open.keyEquivalent = ","
    open.attributedTitle = bold("Open Tidewall…")
    m.addItem(open)
    m.addItem(.separator())
    addThemeMenus(to: m)
    m.addItem(.separator())
    addSwitches(to: m)
    m.addItem(.separator())
    m.addItem(ClosureItem("Check for Updates…") { [weak self] in self?.app.updater.check(manual: true) })
    m.addItem(ClosureItem("Quit Tidewall") { NSApp.terminate(nil) })
    item.menu = m
  }

  private func changed() {
    rebuild()
    app.appWindow.pushState()
  }

  private func bold(_ s: String, color: NSColor? = nil) -> NSAttributedString {
    var a: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)]
    if let color { a[.foregroundColor] = color }
    return NSAttributedString(string: s, attributes: a)
  }

  private func addNotices(to m: NSMenu) {
    if Cfg.hasNewNotes {
      let title = "What’s New in Tidewall \(Cfg.version)…"
      let wn = ClosureItem(title) { [weak self] in self?.app.appWindow.show(page: "whatsnew") }
      wn.attributedTitle = bold(title)
      m.addItem(wn)
      m.addItem(.separator())
    }
    switch app.updater.state {
    case .ready(let v):
      let u = ClosureItem("Restart to Update to \(v)") { [weak self] in self?.app.updater.install() }
      u.attributedTitle = bold("Restart to Update to \(v)", color: .controlAccentColor)
      m.addItem(u)
    case .downloading(let v):
      let u = NSMenuItem(title: "Downloading Tidewall \(v)…", action: nil, keyEquivalent: "")
      u.isEnabled = false
      m.addItem(u)
    case .blocked(let v, let why):
      let u = ClosureItem("Move to Applications to Update to \(v)") { [weak self] in self?.app.updater.install() }
      u.toolTip = why
      m.addItem(u)
    default:
      return
    }
    m.addItem(.separator())
  }

  // MARK: usage readout

  private func addUsageReadout(to m: NSMenu) {
    for (i, title) in ["CPU  –", "GPU  –", "Memory  –", ""].enumerated() {
      let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      it.isEnabled = false
      it.tag = Self.usageTag + i
      it.isHidden = title.isEmpty
      it.attributedTitle = NSAttributedString(string: title, attributes: [.font: mono])
      m.addItem(it)
    }
  }

  func menuWillOpen(_ menu: NSMenu) {
    // a minute of marks gives an average straight away; just started, take a baseline and show figures 2 s on
    let ready = app.usage.window >= 10
    if !ready { _ = app.usage.sample() }
    refreshUsage(menu, first: !ready)
    let t = Timer(timeInterval: 2, repeats: true) { [weak self, weak menu] _ in
      if let menu { self?.refreshUsage(menu, first: false) }
    }
    RunLoop.main.add(t, forMode: .common)
    usageTimer = t
  }

  func menuDidClose(_ menu: NSMenu) {
    usageTimer?.invalidate()
    usageTimer = nil
  }

  /// Tidewall's own use, the app window's apart (it's freed when the window closes).
  private func refreshUsage(_ menu: NSMenu, first: Bool) {
    let lines: [String]
    if first {
      lines = ["CPU     measuring…", "GPU     measuring…", "Memory  measuring…", ""]
    } else {
      let s = app.usage.sample()
      let ui = pid_t(app.appWindow.web.map(webPid) ?? -1)
      let windowCPU = s.cpuBy[ui] ?? 0, windowMem = s.memBy[ui] ?? 0
      let avg = app.usage.window >= 30 ? "  last minute" : ""
      lines = [String(format: "CPU     %.1f%%", max(0, s.cpu - windowCPU)) + avg,
               String(format: "GPU     %.1f%%", s.gpu) + avg + (windowMem > 0 ? "  incl. window" : ""),
               String(format: "Memory  %.0f MB", max(0, s.memMB - windowMem)),
               windowMem > 0 ? String(format: "+ window %.0f MB, freed on close", windowMem) : ""]
    }
    for (i, l) in lines.enumerated() {
      guard let it = menu.item(withTag: Self.usageTag + i) else { continue }
      it.isHidden = l.isEmpty
      it.attributedTitle = NSAttributedString(string: l, attributes: [.font: mono])
    }
  }

  // MARK: themes

  private typealias Choice = (title: String, on: Bool, pick: () -> Void)

  private func addSubmenu(_ title: String, _ choices: [Choice], to m: NSMenu) {
    let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let sub = NSMenu()
    for c in choices {
      let i = ClosureItem(c.title, c.pick)
      i.state = c.on ? .on : .off
      // "Name · tier": the resource tier in quiet grey after the name
      let parts = c.title.components(separatedBy: " · ")
      if parts.count == 2 {
        let a = NSMutableAttributedString(string: parts[0], attributes: [.font: NSFont.menuFont(ofSize: 0)])
        a.append(NSAttributedString(string: "   " + parts[1],
                                    attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        i.attributedTitle = a
      }
      sub.addItem(i)
    }
    it.submenu = sub
    m.addItem(it)
  }

  private func addThemeMenus(to m: NSMenu) {
    let screens = NSScreen.screens
    let several = screens.count > 1
    let hasOwnTheme = { (id: CGDirectDisplayID) in Cfg.d.string(forKey: "theme.display.\(id)") != nil }

    if several {
      let names = displayNames()
      for s in screens {
        let id = s.displayID, own = hasOwnTheme(id)
        let pick = { [unowned self] (theme: String?) in
          Cfg.setTheme(theme, for: id)
          app.reloadWall(id)
          app.resendDesks()
          changed()
        }
        let inherit = s == screens.first ? "Default (\(Cfg.label(Cfg.theme)))" : "Same as Main (\(Cfg.label(Cfg.theme)))"
        let choices: [Choice] = [(inherit, !own, { pick(nil) })]
          + Cfg.themes.map { (tid, label) in (label, own && Cfg.theme(for: id) == tid, { pick(tid) }) }
        addSubmenu("\(names[id] ?? s.localizedName) — \(Cfg.label(Cfg.theme(for: id)))", choices, to: m)
      }
    }

    // the main theme, on every display (choosing it clears any per-display themes)
    let showing = Set(screens.map { Cfg.theme(for: $0.displayID) })
    let anyOwn = screens.contains { hasOwnTheme($0.displayID) }
    let choices: [Choice] = Cfg.themes.map { (id, label) in
      (label, several ? Cfg.theme == id && !anyOwn : showing.contains(id), { [unowned self] in
        Cfg.clearDisplayThemes()
        Cfg.theme = id
        app.reloadAll()
        changed()
      })
    }
    addSubmenu(several ? "All Displays" : "Wall", choices, to: m)
  }

  // MARK: switches

  private func addSwitches(to m: NSMenu) {
    let pause = ClosureItem("Pause") { [unowned self] in
      app.userPaused.toggle()
      app.dispatch(live: false)
      changed()
    }
    pause.state = app.userPaused ? .on : .off
    m.addItem(pause)

    let rest = ClosureItem("Rest when idle") { [unowned self] in
      Cfg.idleMinutes = Cfg.idleMinutes > 0 ? 0 : Cfg.idleLast
      changed()
    }
    rest.state = Cfg.idleMinutes > 0 ? .on : .off
    m.addItem(rest)

    let login = ClosureItem(LoginItem.blocked ? "Open at login (allow in System Settings…)" : "Open at login") { [unowned self] in
      if LoginItem.blocked {
        SMAppService.openSystemSettingsLoginItems()
        return
      }
      if let why = LoginItem.set(!LoginItem.enabled) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = why
        a.runModal()
      }
      changed()
    }
    login.state = LoginItem.enabled && !LoginItem.blocked ? .on : .off
    m.addItem(login)
  }
}
