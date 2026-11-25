import Cocoa

/// Where Finder shows the desktop icons (opt-in), so each theme can keep them clear. Finder answers one Apple event (macOS
/// asks the user once) every 3 s and after a drag. Each icon is a box of image and label in global CG points; neighbours
/// are grouped into clusters, so a column of icons is one tall shape rather than twenty specks.
final class DeskIcons {
  enum State: String { case off, ok, denied, failed }
  typealias Geometry = (icon: CGFloat, text: CGFloat, bottom: Bool)

  static weak var shared: DeskIcons?
  /// Whole icons (image and label), clusters of neighbouring ones, and the images alone.
  private(set) var icons: [CGRect] = []
  private(set) var clusters: [CGRect] = []
  private(set) var images: [CGRect] = []
  /// The visible artwork inside each image (a folder sits low in its square, a document is narrow): read from the icon
  /// macOS shows for each file, once per file. Empty until known; then one per image, in the same order.
  private(set) var artworks: [CGRect] = []
  private var artPoints: [CGPoint] = [], artFetching = false
  private var urlScript: NSAppleScript?
  private static var artCache: [String: CGRect] = [:]   // file path → artwork as a fraction of its icon square
  private(set) var state = State.off
  /// Icons have been read since launch (until then, the last launch's "iconsPresent" stands in).
  private(set) var known = false
  var onChange: () -> Void = {}
  /// Whether the wallpaper rests (paused, idle, asleep, let go, paused on battery): no need to ask Finder then.
  var resting: () -> Bool = { false }
  /// Dev (--fakeicons): pretend icons, each a box and its image.
  var fake: [(CGRect, CGRect)]?

  private var script: NSAppleScript?
  private var timer: Timer?
  private var monitor: Any?
  private var busy = false
  private var lastClick = 0.0

  /// NSAppleScript (an OSA component) isn't thread-safe: it's made and run on this one thread, always the same.
  private static let worker: CFRunLoop = {
    var loop: CFRunLoop?
    let ready = DispatchSemaphore(value: 0)
    let t = Thread {
      loop = CFRunLoopGetCurrent()
      RunLoop.current.add(NSMachPort(), forMode: .default)
      ready.signal()
      while true { RunLoop.current.run(mode: .default, before: .distantFuture) }
    }
    t.name = "tidewall.desk-icons"
    t.qualityOfService = .utility
    t.start()
    ready.wait()
    return loop!
  }()

  private func onWorker(_ f: @escaping () -> Void) {
    let rl = Self.worker
    CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue, f)
    CFRunLoopWakeUp(rl)
  }

  func start() {
    stop()
    guard Cfg.deskIcons || fake != nil else {
      state = .off
      set([])
      return
    }
    if let fake {
      state = .ok
      set(fake.map(\.0), fake.map(\.1))
      return
    }
    timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.read() }
    read()
    timer?.tolerance = 0.5
    // an icon dragged to a new spot: look again as soon as it's dropped, at most once a second
    monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
      guard let self, ProcessInfo.processInfo.systemUptime - lastClick > 1 else { return }
      lastClick = ProcessInfo.processInfo.systemUptime
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.read() }
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    if let m = monitor { NSEvent.removeMonitor(m) }
    monitor = nil
  }

  func read() {
    guard !busy, Cfg.deskIcons, timer != nil, !resting() else { return }
    if Self.hidden() {
      let stateChanged = state != .ok
      state = .ok
      if !set([]) && stateChanged { onChange() }   // (once, whichever changed)
      return
    }
    busy = true
    let g = Self.geometry()
    onWorker { [weak self] in
      guard let self else { return }
      let (points, code) = askFinder()
      DispatchQueue.main.async { self.received(points, error: code, g) }
    }
  }

  /// On the worker thread: where Finder says each icon's image is centred, or the Apple event's error number.
  private func askFinder() -> (points: [CGPoint], error: Int?) {
    if script == nil {
      script = NSAppleScript(source: "with timeout of 3 seconds\ntell application \"Finder\" to get desktop position of every item of desktop\nend timeout")
    }
    var err: NSDictionary?
    let d = script?.executeAndReturnError(&err)
    var points: [CGPoint] = []
    if err == nil, let d, d.numberOfItems > 0 {
      for i in 1...d.numberOfItems {
        if let p = d.atIndex(i), p.numberOfItems >= 2, let x = p.atIndex(1)?.int32Value, let y = p.atIndex(2)?.int32Value {
          points.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
        }
      }
    }
    return (points, (err?[NSAppleScript.errorNumber] as? NSNumber)?.intValue)
  }

  private func received(_ points: [CGPoint], error code: Int?, _ g: Geometry) {
    busy = false
    guard Cfg.deskIcons else { return }
    let before = state
    defer { if state != before { onChange() } }
    switch code {
    case nil:
      state = .ok
      set(points.map { Self.box($0, g) }, points.map { Self.image($0, g) })
      readArtworks(points, g)
    case -1743, -1744:
      if state != .denied { log("[icons] not allowed to ask Finder (System Settings ▸ Privacy & Security ▸ Automation)") }
      state = .denied
      set([])
    case -600:   // Finder isn't running: no desktop icons
      state = .ok
      set([])
    default:
      if state != .failed { log("[icons] couldn't read them (\(code!))") }
      state = .failed
    }
  }

  /// True if the icons changed (the pages have then been told).
  @discardableResult
  private func set(_ rs: [CGRect], _ ims: [CGRect] = []) -> Bool {
    known = true
    // remembered so the next launch opens Wind Tunnel on the right model before Finder has answered
    if Cfg.d.bool(forKey: "iconsPresent") != !rs.isEmpty { Cfg.d.set(!rs.isEmpty, forKey: "iconsPresent") }
    if rs == icons && ims == images { return false }   // checked before clustering: that's the costly part
    let cl = Self.cluster(rs)
    icons = rs
    clusters = cl
    images = ims
    onChange()
    return true
  }

  /// The icons moved, came or went: which files they are (one more question to Finder, only then), and the artwork of
  /// each; pictures show a preview fitted to their own shape, everything else the icon macOS draws for it.
  private func readArtworks(_ points: [CGPoint], _ g: Geometry) {
    if points == artPoints { return }   // (same icons in the same places: already known)
    guard !artFetching else { return }
    artFetching = true
    onWorker { [weak self] in
      guard let self else { return }
      if urlScript == nil { urlScript = NSAppleScript(source: "with timeout of 3 seconds\ntell application \"Finder\" to get URL of every item of desktop\nend timeout") }
      var err: NSDictionary?
      let d = urlScript?.executeAndReturnError(&err)
      var urls: [String] = []
      if err == nil, let d, d.numberOfItems > 0 { for i in 1...d.numberOfItems { urls.append(d.atIndex(i)?.stringValue ?? "") } }
      DispatchQueue.main.async {
        self.artFetching = false
        guard urls.count == points.count else { return }   // (the desktop changed between the two questions: next time)
        self.artPoints = points
        let arts = zip(points, urls).map { p, u -> CGRect in
          let img = Self.image(p, g), f = Self.artwork(u)
          return CGRect(x: img.minX + f.minX * img.width, y: img.minY + f.minY * img.height, width: f.width * img.width, height: f.height * img.height)
        }
        if arts != self.artworks { self.artworks = arts; self.onChange() }
      }
    }
  }

  /// A file's artwork as a fraction of its icon square (top-left origin).
  private static func artwork(_ url: String) -> CGRect {
    guard let u = URL(string: url), u.isFileURL else { return CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8) }
    if let c = artCache[u.path] { return c }
    var r = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    // a picture: Finder shows its preview, fitted into the square with a small margin
    if let src = CGImageSourceCreateWithURL(u as CFURL, nil), CGImageSourceGetType(src) != nil,
       let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
       let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue, let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 {
      let m = 0.06, fw = w >= h ? 1 - 2 * m : (1 - 2 * m) * w / h, fh = h >= w ? 1 - 2 * m : (1 - 2 * m) * h / w
      r = CGRect(x: (1 - fw) / 2, y: (1 - fh) / 2, width: fw, height: fh)
    } else if let b = opaqueBounds(NSWorkspace.shared.icon(forFile: u.path)) {
      r = b
    }
    artCache[u.path] = r
    return r
  }

  /// Where an icon image actually has paint, as a fraction of its square (top-left origin).
  private static func opaqueBounds(_ img: NSImage) -> CGRect? {
    let n = 64
    guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
    guard let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    var x0 = n, y0 = n, x1 = -1, y1 = -1
    for y in 0..<n { for x in 0..<n where px[(y * n + x) * 4 + 3] > 40 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
    guard x1 >= x0, y1 >= y0 else { return nil }
    // (the bitmap's first row is the image's top)
    return CGRect(x: Double(x0) / Double(n), y: Double(y0) / Double(n), width: Double(x1 - x0 + 1) / Double(n), height: Double(y1 - y0 + 1) / Double(n))
  }

  static func geometry() -> Geometry {
    CFPreferencesAppSynchronize("com.apple.finder" as CFString)
    let desktop = CFPreferencesCopyAppValue("DesktopViewSettings" as CFString, "com.apple.finder" as CFString) as? [String: Any]
    let s = desktop?["IconViewSettings"] as? [String: Any]
    let icon = (s?["iconSize"] as? NSNumber)?.doubleValue ?? 64
    let text = (s?["textSize"] as? NSNumber)?.doubleValue ?? 12
    let bottom = (s?["labelOnBottom"] as? NSNumber)?.boolValue ?? true
    return (CGFloat(min(512, max(16, icon))), CGFloat(min(24, max(9, text))), bottom)
  }

  /// An icon's box from the centre of its image (what Finder reports), with a label of up to two lines below or beside it.
  static func box(_ c: CGPoint, _ g: Geometry) -> CGRect {
    let img = image(c, g)
    let lh = g.text * 1.3 * 2 + 4
    let label: CGRect
    if g.bottom {
      let w = max(g.icon + 20, g.text * 7)
      label = CGRect(x: c.x - w / 2, y: img.maxY + 2, width: w, height: lh)
    } else {
      label = CGRect(x: img.maxX + 4, y: c.y - lh / 2, width: g.text * 10, height: lh)
    }
    return img.union(label)
  }

  static func image(_ c: CGPoint, _ g: Geometry) -> CGRect {
    CGRect(x: c.x - g.icon / 2, y: c.y - g.icon / 2, width: g.icon, height: g.icon)
  }

  private static func cluster(_ rs: [CGRect], gap: CGFloat = 26) -> [CGRect] {
    let halo = { (r: CGRect) in r.insetBy(dx: -gap / 2, dy: -gap / 2) }
    var out = rs
    var merged = true
    while merged {
      merged = false
      search: for i in 0..<out.count {
        for j in (i + 1)..<max(i + 1, out.count) where halo(out[i]).intersects(halo(out[j])) {
          out[i] = out[i].union(out[j])
          out.remove(at: j)
          merged = true
          break search
        }
      }
    }
    return out
  }

  /// Icons macOS isn't showing (Finder's desktop switched off, or "Show items" off in Desktop & Dock, on the desktop or
  /// in Stage Manager): Finder still knows where they are, but there's nothing to make room for.
  private static func hidden() -> Bool {
    let f = "com.apple.finder" as CFString, wm = "com.apple.WindowManager" as CFString
    CFPreferencesAppSynchronize(f)
    CFPreferencesAppSynchronize(wm)
    if (CFPreferencesCopyAppValue("CreateDesktop" as CFString, f) as? Bool) == false { return true }
    let stage = (CFPreferencesCopyAppValue("GloballyEnabled" as CFString, wm) as? Bool) ?? false
    return (CFPreferencesCopyAppValue((stage ? "HideDesktop" : "StandardHideDesktopIcons") as CFString, wm) as? Bool) ?? false
  }
}
