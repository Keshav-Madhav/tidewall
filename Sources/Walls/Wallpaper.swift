import Cocoa
import WebKit

/// One display's wallpaper: a desktop-level window holding the page that draws its theme, kept in step with the windows
/// over it, the pointer, the desk around it and whether it should be drawing at all.
final class Wallpaper: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  /// The pages showing now: a new one joins their web process (one process for every display, theme after theme).
  static let live = NSHashTable<WKWebView>.weakObjects()

  let screenID: CGDirectDisplayID
  /// The screen in CG global coordinates (top-left origin), points.
  var cgFrame: CGRect
  let window: NSWindow
  let web: WKWebView

  private(set) var ready = false
  private(set) var paused: Bool?
  var onShown: (() -> Void)?
  /// What the page was opened with (Wind Tunnel's automatic choice can change under it).
  private(set) var loadedVariant: String?
  var realRects: [CGRect] = []
  /// When it first ran on show: a picture of it a few seconds on shows the scene.
  var seenSince: Double?
  /// Its display below the menu bar and beside the Dock (nil: all of it).
  var usable: CGRect?

  /// The most device pixels per point the page draws at, fixed when it's made: the devicePixelRatio it was given.
  private let cap: CGFloat
  private var scale: CGFloat { min(window.backingScaleFactor, cap) * res }
  private let res: CGFloat

  private struct Sent { var windows = "", icons = "", desk = "", deskIcons = "", area = "" }
  private var lastSent = Sent()
  private var lastLayout: (rects: [CGRect], owners: [String], pause: Bool)?
  private var pending: (() -> Void)?
  /// A theme that ignores the pointer says so ("nocursor"): no 120 Hz messages for it.
  private(set) var wantsCursor = true
  private var wasOverWindow = false
  private var lastOverSend = 0.0
  private var crashes: [Double] = []

  private static let pageFiles = [
    "beach": "flat", "meadow": "meadow", "inkmap": "inkmap", "celestial": "celestial", "snow": "snow", "reef": "reef",
    "wind": "wind", "lava": "lava", "tunnel": "tunnel", "gallery": "gallery", "garden": "garden", "railway": "railway",
    "courtyard": "courtyard",
  ]

  init(screen: NSScreen, hidden: Bool = false, fakeID: CGDirectDisplayID? = nil, fakeFrame: CGRect? = nil) {
    let id = fakeID ?? screen.displayID
    screenID = id
    cgFrame = fakeFrame ?? screen.cgFrame
    let cap = min(stock ? 8 : CGFloat(Cfg.renderCap(Cfg.theme(for: id))), fakeID.flatMap { fakeScale[$0] } ?? 8)
    self.cap = cap
    self.res = stock ? 1 : CGFloat(Cfg.tierRes)
    let winRect = fakeFrame.map { NSRect(x: screen.frame.minX, y: screen.frame.minY, width: $0.width, height: $0.height) }
      ?? screen.frame
    let config = Wallpaper.configuration(cap: cap, maxHz: screen.maximumFramesPerSecond)
    window = .wallpaperWindow(winRect, freeSize: fakeFrame != nil)
    window.backgroundColor = NSColor(red: 0.914, green: 0.847, blue: 0.706, alpha: 1)
    web = WKWebView(frame: NSRect(origin: .zero, size: winRect.size), configuration: config)
    Wallpaper.live.add(web)
    web.setValue(false, forKey: "drawsBackground")
    super.init()
    config.userContentController.add(WeakHandler(self), name: "host")
    web.navigationDelegate = self
    if benchMode { Wallpaper.keepDrawingWhenOccluded(web) }
    window.contentView = web
    window.setFrame(winRect, display: false)
    if hidden { window.alphaValue = 0 }   // built behind the still picture; shown once it has drawn
    window.showAtDesktopLevel()
    load()
  }

  /// Every screen's page in ONE web process: the engine, its libraries and caches are paid for once, not per display.
  private static func configuration(cap: CGFloat, maxHz: Int) -> WKWebViewConfiguration {
    let cfg = WKWebViewConfiguration()
    let relate = NSSelectorFromString("_setRelatedWebView:")
    if let other = live.allObjects.first, cfg.responds(to: relate) { cfg.perform(relate, with: other) }
    cfg.setURLSchemeHandler(SchemeHandler(), forURLScheme: "tidewall")
    cfg.suppressesIncrementalRendering = true
    unlockHighRefresh(cfg.preferences)

    let ucc = cfg.userContentController
    if let k = argValue("--timescale").flatMap(Double.init), k != 1 {
      ucc.addUserScript(WKUserScript(source: timescaleScript(k), injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }
    let opaque = !stock && !args.contains("--no-opaque")
    let early = earlyScript(fps: stock ? 0 : Cfg.fps, opaque: opaque, cap: Double(cap), maxHz: maxHz, tier: stock ? 1 : Cfg.tier, res: stock ? 1 : Cfg.tierRes)
    ucc.addUserScript(WKUserScript(source: early, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    ucc.addUserScript(WKUserScript(source: lateScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    return cfg
  }

  private static func keepDrawingWhenOccluded(_ web: WKWebView) {
    let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
    guard web.responds(to: sel), let imp = class_getMethodImplementation(type(of: web), sel) else { return }
    typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
    unsafeBitCast(imp, to: Setter.self)(web, sel, false)
  }

  func load() {
    ready = false
    paused = nil
    lastSent = Sent()
    wantsCursor = true
    seenSince = nil
    let page = Self.pageFiles[Cfg.theme(for: screenID)] ?? "estate"
    loadedVariant = Cfg.variant(Cfg.theme(for: screenID))
    let v = loadedVariant.flatMap { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) }.map { "&v=\($0)" } ?? ""
    web.load(URLRequest(url: URL(string: "tidewall://app/\(page).html?wallpaper=1\(v)\(Cfg.siteQuery)")!))
  }

  func close() {
    Wallpaper.live.remove(web)
    web.stopLoading()
    window.orderOut(nil)
    window.close()
  }

  func send(_ json: String, live: Bool = false) { send([json], live: live) }

  /// Several messages in one go (one trip to the page, and it never draws with only some of them in).
  func send(_ jsons: [String], live: Bool = false) {
    guard ready, !jsons.isEmpty else { return }
    let lit = String(data: try! JSONSerialization.data(withJSONObject: jsons), encoding: .utf8)!
    web.evaluateJavaScript("window.__live=\(live);\(lit).forEach(s=>window.__hostSend(s));window.__live=false;null", completionHandler: nil)
  }

  // MARK: messages from the page

  func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
    let message = "\(m.body)"
    switch message {
    case "nocursor":
      wantsCursor = false
    case "ready":
      if window.alphaValue < 1 { fadeIn() }
      pageReady()
    default:
      if Self.isWorthLogging(message) { log("[\(screenID)] \(message)") }
    }
  }

  private static func isWorthLogging(_ s: String) -> Bool {
    s.hasPrefix("JSERR") || s.hasPrefix("NOTE") || s == "patched"
      || (s.hasPrefix("STAT") && ProcessInfo.processInfo.environment["TIDEWALL_STAT"] != nil)
  }

  private func fadeIn() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
      guard let self else { return }
      NSAnimationContext.runAnimationGroup { c in
        c.duration = 0.35
        self.window.animator().alphaValue = 1
      } completionHandler: {
        self.onShown?()
        self.onShown = nil
      }
    }
  }

  private func pageReady() {
    ready = true
    lastSent = Sent()
    paused = nil
    sendDesk()
    send("{\"t\":\"me\",\"seed\":\(Cfg.seed)}")
    sendDeskIcons()
    if delegate.power.pace != 1 { sendPace() }
    if let p = pending {
      pending = nil
      p()
    } else if let last = lastLayout {
      update(rects: last.rects, owners: last.owners, live: false, pause: last.pause)
    }
  }

  func webViewWebContentProcessDidTerminate(_ w: WKWebView) {
    let now = ProcessInfo.processInfo.systemUptime
    crashes = crashes.filter { now - $0 < 60 } + [now]
    let wait = crashes.count > 2 ? 10.0 : 0   // crashing over and over: give the system a moment
    log("[\(screenID)] web process died; reloading\(wait > 0 ? " in \(Int(wait)) s" : "")")
    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.load() }
  }

  /// Pages draw at their own pace × k (2 on battery when Settings says calmer).
  func sendPace() {
    guard ready else { return }
    send("{\"t\":\"pace\",\"k\":\(delegate.power.pace)}")
  }

  private func setPaused(_ on: Bool) {
    paused = on
    send(on ? "{\"t\":\"pause\",\"v\":true}" : "{\"t\":\"pause\",\"v\":false}")
  }

  private func pauseSoon() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self, lastLayout?.pause == true, paused != true else { return }
      setPaused(true)
    }
  }

  /// A paused page whose screen changed size has had its canvas cleared by the resize and won't draw until it's resumed
  /// (a black or half-blank screen, which the away still could then capture): let it run a moment to redraw, then pause.
  func redrawIfPaused() {
    guard paused == true else { return }
    setPaused(false)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self, lastLayout?.pause == true, paused == false else { return }
      setPaused(true)
    }
  }

  // MARK: windows

  /// The windows over this screen (CG global points) and their owners' names; `live`: your hand is on one of them.
  func update(rects: [CGRect], owners: [String], live: Bool, pause: Bool) {
    lastLayout = (rects, owners, pause)
    guard ready else {
      pending = { [weak self] in self?.update(rects: rects, owners: owners, live: live, pause: pause) }
      return
    }
    // A page paused before it ever laid out (relaunched while paused, or a theme changed while paused) lays out around
    // your windows once, draws, and only then pauses: otherwise it would freeze a scene that ignores them.
    let firstLayout = lastSent.windows.isEmpty
    if pause && !firstLayout {
      if paused != true { setPaused(true) }
      return
    }
    if !pause && paused != false { setPaused(false) }
    if pause && firstLayout { pauseSoon() }

    let k = scale, o = cgFrame.origin
    let local = rects.map { $0.offsetBy(dx: -o.x, dy: -o.y) }
    send([windowsMessage(local, rects: rects, owners: owners, scale: k, live: live), roomMessage(local, scale: k, live: live), areaMessage(scale: k)].compactMap { $0 }, live: live)
  }

  /// The part of the display you see the wallpaper in: below the menu bar, above (or beside) the Dock. A wall that sets
  /// things on the ground (Snowfall's bank of snow) puts them on this bottom edge, not behind the Dock.
  private func areaMessage(scale k: CGFloat) -> String? {
    let a = (usable ?? cgFrame).offsetBy(dx: -cgFrame.minX, dy: -cgFrame.minY)
    let m = "{\"t\":\"area\",\"r\":\(boxJSON(a, scale: k))}"
    guard m != lastSent.area else { return nil }
    lastSent.area = m
    return m
  }

  /// The windows' own edges and app names, for themes that draw around the real window (Estate, say).
  private func windowsMessage(_ local: [CGRect], rects: [CGRect], owners: [String], scale k: CGFloat, live: Bool) -> String? {
    let raw = local.map { boxJSON($0, scale: k) }.joined(separator: ",")
    // Desktop widgets reach the themes under one name, whatever this Mac's language calls Notification Center.
    let named = owners.enumerated().map { i, o in
      i < rects.count && Tracker.widgetRects.contains("\(rects[i])") ? "Notification Centre" : o
    }
    let names = String(data: try! JSONSerialization.data(withJSONObject: named), encoding: .utf8)!
    let sm = rects.map { Tracker.stageRects.contains("\($0)") ? "1" : "0" }.joined(separator: ",")
    let wins = "{\"t\":\"windows\",\"live\":\(live),\"r\":[\(raw)],\"n\":\(names),\"sm\":[\(sm)]}"
    guard wins != lastSent.windows else { return nil }
    lastSent.windows = wins
    return wins
  }

  private func roomMessage(_ local: [CGRect], scale k: CGFloat, live: Bool = false) -> String? {
    let m = Cfg.margin
    let icons = local.map { boxJSON($0.insetBy(dx: -m, dy: -m), scale: k) }.joined(separator: ",")
    // compared whole: with no windows the list is empty, and an empty list compared bare matched "never sent", so a
    // page opened on an empty desk never heard it and drew nothing until the first window appeared
    // live: a window is in your hand (walls that only read this message can tell a drag from a settle)
    let message = "{\"t\":\"icons\",\"vis\":true,\"live\":\(live),\"r\":[\(icons)]}"
    guard message != lastSent.icons else { return nil }
    lastSent.icons = message
    return message
  }

  func cursor(_ p: CGPoint) {
    guard wantsCursor, Cfg.reactCursor else { return }
    let k = scale
    // over a window, the menu bar or the Dock you're working, not watching: 10 messages a second, not 60, and no speed-up
    let over = realRects.contains { $0.contains(p) } || (usable.map { !$0.contains(p) } ?? false)
    let now = ProcessInfo.processInfo.systemUptime
    if over && wasOverWindow && now - lastOverSend < 0.1 { return }
    wasOverWindow = over
    if over { lastOverSend = now }
    let x = Int((p.x - cgFrame.minX) * k), y = Int((p.y - cgFrame.minY) * k)
    send("{\"t\":\"cursor\",\"x\":\(x),\"y\":\(y)\(over ? ",\"w\":1" : "")}")
  }

  // MARK: the desk

  private var spansWorld: Bool { Cfg.spanThemes.contains(Cfg.theme(for: screenID)) }

  /// Where this screen sits among all of them: themes continue one world across displays (the sky, the map, the painted
  /// panorama) and never repeat the same thing on every screen.
  func sendDesk() {
    let (frames, me, main) = deskFrames()
    let u = frames.reduce(frames.first ?? me) { $0.union($1) }
    let i = Self.readingOrder(frames).firstIndex(of: me) ?? 0
    let fr = frames.map {
      "[\(Int($0.minX - u.minX)),\(Int($0.minY - u.minY)),\(Int($0.width)),\(Int($0.height))]"
    }.joined(separator: ",")
    let msg = "{\"t\":\"desk\",\"fr\":[\(fr)],\"x\":\(me.minX - u.minX),\"y\":\(me.minY - u.minY),"
      + "\"w\":\(me.width),\"h\":\(me.height),\"uw\":\(u.width),\"uh\":\(u.height),\"i\":\(i),\"n\":\(frames.count),"
      + "\"mx\":\(main.midX - u.minX),\"my\":\(main.midY - u.minY),\"mw\":\(main.width),\"mh\":\(main.height)}"
    send(msg)
    // pages place icons by their world offset, which a new desk may have moved
    if msg != lastSent.desk {
      lastSent.desk = msg
      lastSent.deskIcons = ""
      sendDeskIcons()
    }
  }

  private func deskFrames() -> (frames: [CGRect], me: CGRect, main: CGRect) {
    let frames = spansWorld ? worldFrames(for: screenID) : allFrames()
    let mainFrame = fakeWorld.isEmpty
      ? (NSScreen.screens.first?.cgFrame ?? cgFrame)
      : CGRect(origin: .zero, size: NSScreen.screens.first?.frame.size ?? .zero)
    let main = frames.first { $0 == mainFrame } ?? frames.first ?? cgFrame
    if let f = argValue("--fakedesk"), let i = Int(f) { return pretendDesk(screen: i) }
    return (frames, cgFrame, main)
  }

  /// Bench (--fakedesk I): screen I of external | built-in | external, or (--stacked) of two monitors above the laptop.
  private func pretendDesk(screen i: Int) -> (frames: [CGRect], me: CGRect, main: CGRect) {
    let b = cgFrame
    let frames = args.contains("--stacked")
      ? [CGRect(x: b.minX - 1533, y: b.minY - 1080, width: 1920, height: 1080),
         CGRect(x: b.minX + 387, y: b.minY - 1080, width: 1920, height: 1080), b]
      : [CGRect(x: b.minX - 1920, y: b.minY - 98, width: 1920, height: 1080), b,
         CGRect(x: b.maxX, y: b.minY - 98, width: 1920, height: 1080)]
    return (frames, frames[min(frames.count - 1, max(0, i))], b)
  }

  private static func readingOrder(_ frames: [CGRect]) -> [CGRect] {
    var rows: [[CGRect]] = []
    for f in frames.sorted(by: { $0.midY < $1.midY }) {
      if let r = rows.firstIndex(where: { row in row.contains { min($0.maxY, f.maxY) - max($0.minY, f.minY) > 40 } }) {
        rows[r].append(f)
      } else {
        rows.append([f])
      }
    }
    return rows.flatMap { $0.sorted { $0.minX < $1.minX } }
  }

  /// The desktop icons in this page's world, their clusters and their images, in its device pixels (none when it's off).
  func sendDeskIcons() {
    guard ready, let di = DeskIcons.shared else { return }
    let world = spansWorld ? worldFrames(for: screenID) : [cgFrame]
    let k = scale, o = cgFrame.origin
    func encode(_ rects: [CGRect]) -> String {
      rects.filter { r in world.contains { $0.intersects(r) } }
        .map { boxJSON($0.offsetBy(dx: -o.x, dy: -o.y), scale: k) }
        .joined(separator: ",")
    }
    // a: each image's visible artwork, in step with i (until it's known, the image itself)
    let shown = di.images.indices.filter { i in world.contains { $0.intersects(di.images[i]) } }
    let arts = di.artworks.count == di.images.count ? shown.map { di.artworks[$0] } : shown.map { di.images[$0] }
    let a = arts.map { boxJSON($0.offsetBy(dx: -o.x, dy: -o.y), scale: k) }.joined(separator: ",")
    let msg = "{\"t\":\"dicons\",\"r\":[\(encode(di.icons))],\"c\":[\(encode(di.clusters))],\"i\":[\(encode(di.images))],\"a\":[\(a)]}"
    if msg != lastSent.deskIcons {
      lastSent.deskIcons = msg
      send(msg)
    }
  }
}

private func boxJSON(_ r: CGRect, scale k: CGFloat = 1) -> String {
  "[\(Int(r.minX * k)),\(Int(r.minY * k)),\(Int(r.maxX * k)),\(Int(r.maxY * k))]"
}

/// Passes script messages on without keeping its target alive (a user content controller retains its handlers).
final class WeakHandler: NSObject, WKScriptMessageHandler {
  weak var target: WKScriptMessageHandler?

  init(_ t: WKScriptMessageHandler) { target = t }

  func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
    target?.userContentController(u, didReceive: m)
  }
}
