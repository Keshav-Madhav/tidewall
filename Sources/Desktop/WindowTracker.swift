import Cocoa

/// Where every window is, from the window list (which needs no permission): a look 4 times a second while nothing moves,
/// at 120 Hz from the moment the mouse moves or an app activates, hides, launches or quits.
final class Tracker {
  var onUpdate: (_ rects: [CGRect], _ live: Bool) -> Void = { _, _ in }
  var onCursor: (CGPoint) -> Void = { _ in }
  private(set) var owners: [String] = []
  private(set) var polls = 0
  private(set) var pollMs = 0.0

  static var idle = false
  static var allHidden = false
  /// Stage Manager thumbnails and badges seen in the last read (macOS draws them tilted).
  static var stageRects = Set<String>()
  static var widgetRects = Set<String>()
  private static var widgetPid: [pid_t: Bool] = [:]

  private static let idleInterval = 0.25

  private let me = ProcessInfo.processInfo.processIdentifier
  private var timer: Timer?
  private var fastTimer = false
  private var timerInterval = 0.0
  private var mouseMonitor: Any?
  private var last: [CGRect] = []
  private var lastPoll = 0.0
  private var burstUntil = 0.0
  private var mouseUntil = 0.0
  private var lastCursor = CGPoint(x: -1, y: -1)
  private var lastCursorT = 0.0
  private var wasDragging = false
  private var activity: NSObjectProtocol?
  private var lastFastT = 0.0

  private struct PollStats { var since = 0.0, polls = 0, updates = 0, maxGap = 0.0 }
  private var stats = PollStats()

  func start() {
    schedule(fast: false)
    let mouse: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
    mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouse) { [weak self] _ in
      guard let self, !Self.idle else { return }
      mouseUntil = now() + 0.4
      schedule(fast: true)
    }
    let nc = NSWorkspace.shared.notificationCenter
    for n in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
              NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
              NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
      nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.burst(1.2) }
    }
  }

  func burst(_ s: Double) {
    burstUntil = max(burstUntil, now() + s)
    lastPoll = 0
    schedule(fast: true)
  }

  func forceResend() {
    last = [CGRect(x: -1, y: -1, width: 0, height: 0)]
    lastPoll = 0
  }

  private func now() -> Double { ProcessInfo.processInfo.systemUptime }

  /// Every screen covered: a look twice a second is plenty.
  private var slowInterval: Double { Self.allHidden ? 0.5 : Self.idleInterval }

  private func schedule(fast: Bool) {
    let interval = fast ? 1.0 / 120 : slowInterval
    if timer != nil && fast == fastTimer && interval == timerInterval { return }
    timer?.invalidate()
    fastTimer = fast
    timerInterval = interval
    let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
    t.tolerance = fast ? 0.002 : 0.03
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  private func tick() {
    let t = now()
    trackCursor(at: t)
    let dragging = NSEvent.pressedMouseButtons & 1 != 0 || SimInput.pressed
    let fast = dragging || t < burstUntil
    if !fast && t > mouseUntil && (fastTimer || timerInterval != slowInterval) { schedule(fast: false) }
    holdLowLatency(fast, at: t)
    // fast: every tick, as the page paces itself to its own fps
    guard fast || t - lastPoll >= (Self.idle ? 2 : slowInterval) else { return }
    if fast && lastPoll > 0 { stats.maxGap = max(stats.maxGap, t - lastPoll) }
    lastPoll = t

    let started = DispatchTime.now().uptimeNanoseconds
    let found = Self.read(excluding: me)
    let rects = found.map { $0.0 }
    pollMs += Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
    polls += 1

    if rects == last {
      if wasDragging && !dragging { onUpdate(rects, false) }
      wasDragging = dragging
      return
    }
    wasDragging = dragging
    last = rects
    owners = found.map { $0.1 }
    if !dragging { burst(0.6) }   // things animate (Stage Manager, minimising): keep watching
    onUpdate(rects, dragging)     // live while your hand is on a window; changes made by macOS always glide
    stats.updates += 1
    logStats(at: t)
  }

  /// The pointer, at most 60 times a second: the pages draw at most 60 fps while you work, so more is only overhead.
  private func trackCursor(at t: Double) {
    guard t - lastCursorT >= 1.0 / 60 else { return }
    let m = SimInput.point ?? NSEvent.mouseLocation
    guard m != lastCursor else { return }
    lastCursor = m
    lastCursorT = t
    if let h = NSScreen.screens.first?.frame.height { onCursor(CGPoint(x: m.x, y: h - m.y)) }
  }

  private func holdLowLatency(_ fast: Bool, at t: Double) {
    if fast && activity == nil {
      activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                       reason: "tracking moving windows")
    } else if !fast, let a = activity, t - lastFastT > 2 {
      ProcessInfo.processInfo.endActivity(a)
      activity = nil
    }
    if fast { lastFastT = t }
  }

  /// Polling while windows move: every second in a test run, every half minute otherwise (in a problem report's log
  /// tail, a line a second of dragging buried everything else).
  private func logStats(at t: Double) {
    guard t - stats.since >= (benchMode ? 1 : 30) else { return }
    let rate = Double(polls - stats.polls) / (t - stats.since)
    log(String(format: "HOST polls/s=%.0f updates=%d maxGap=%dms", rate, stats.updates, Int(stats.maxGap * 1000)))
    stats = PollStats(since: t, polls: polls)
  }

  // MARK: reading the window list

  /// Windows, Stage Manager's strip and desktop widgets at least 40 pt each way, with their owners' names.
  private static func read(excluding me: pid_t) -> [(CGRect, String)] {
    stageRects.removeAll()
    widgetRects.removeAll()
    // Read straight from the CF list, a field at a time: bridging the whole list into Swift dictionaries cost more than
    // the list itself, several times a second. System windows on other layers are dropped before anything else is read.
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) else { return [] }
    var out: [(CGRect, String)] = []
    for i in 0..<CFArrayGetCount(list) {
      let w = unsafeBitCast(CFArrayGetValueAtIndex(list, i), to: CFDictionary.self)
      guard let layer = (field(w, kCGWindowLayer) as? NSNumber)?.intValue, layer <= 0,
            let pid = (field(w, kCGWindowOwnerPID) as? NSNumber)?.int32Value, pid != me || layer == 0,
            let b = field(w, kCGWindowBounds), CFGetTypeID(b) == CFDictionaryGetTypeID(),
            let r = CGRect(dictionaryRepresentation: unsafeBitCast(b, to: CFDictionary.self)), r.width >= 40, r.height >= 40
      else { continue }
      let owner = field(w, kCGWindowOwnerName) as? String ?? ""
      let alpha = (field(w, kCGWindowAlpha) as? NSNumber)?.doubleValue ?? 1
      // desktop widgets live on a layer below the windows
      let widget = layer < 0 && (isWidgetOwner(pid) || owner == "Notification Centre" || owner == "Notification Center")
      guard layer == 0 || widget, alpha > 0.05 else { continue }
      // Stage Manager thumbnails and their apps' proxies share a rect: keep one, named after the app
      if let same = out.firstIndex(where: { $0.0 == r }) {
        if out[same].1 == "WindowManager" { out[same].1 = owner }
        stageRects.insert("\(r)")
      } else {
        out.append((r, owner))
      }
      if owner == "WindowManager" { stageRects.insert("\(r)") }
      if widget { widgetRects.insert("\(r)") }
    }
    return out
  }

  private static func field(_ d: CFDictionary, _ key: CFString) -> AnyObject? {
    CFDictionaryGetValue(d, Unmanaged.passUnretained(key).toOpaque())
      .map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }
  }

  private static func isWidgetOwner(_ pid: pid_t) -> Bool {
    if let known = widgetPid[pid] { return known }
    let isWidget = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.notificationcenterui"
    widgetPid[pid] = isWidget
    return isWidget
  }
}

/// The exact area (pt²) of a screen no window covers: the union of the rects by coordinate compression. A handful of
/// rects take microseconds, and a 2 pt sliver between windows still counts (no sampling to miss it).
func uncoveredArea(_ screen: CGRect, _ rects: [CGRect]) -> Double {
  let rs = rects.map { $0.intersection(screen) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
  if rs.isEmpty { return Double(screen.width * screen.height) }
  let xs = Array(Set(rs.flatMap { [$0.minX, $0.maxX] } + [screen.minX, screen.maxX])).sorted()
  let ys = Array(Set(rs.flatMap { [$0.minY, $0.maxY] } + [screen.minY, screen.maxY])).sorted()
  var free = 0.0
  for i in 0..<(xs.count - 1) {
    for j in 0..<(ys.count - 1) {
      let centre = CGPoint(x: (xs[i] + xs[i + 1]) / 2, y: (ys[j] + ys[j + 1]) / 2)
      if !rs.contains(where: { $0.contains(centre) }) { free += Double((xs[i + 1] - xs[i]) * (ys[j + 1] - ys[j])) }
    }
  }
  return free
}
