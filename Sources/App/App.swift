import Cocoa

/// Owns the wallpapers (one per display), the window tracker that feeds them, and everything that decides whether
/// they draw: covered screens, idle, sleep and lock, battery.
final class App: NSObject, NSApplicationDelegate {
  let usage = Usage()
  let tracker = Tracker()
  let deskIcons = DeskIcons()
  let updater = Updater()
  lazy var appWindow = AppWindow(app: self)
  private(set) var statusMenu: StatusMenu?

  var walls: [CGDirectDisplayID: Wallpaper] = [:]
  var stills: [CGDirectDisplayID: StillWall] = [:]
  var lastRects: [CGRect] = []
  var lastOwners: [String] = []
  weak var cursorWall: Wallpaper?

  var userPaused = benchMode ? args.contains("--paused") : Cfg.d.bool(forKey: "paused") {
    didSet { if !benchMode { Cfg.d.set(userPaused, forKey: "paused") } }
  }
  var locked = false
  var displaysAsleep = false
  var idleRest = false
  var asleep: Bool { locked || displaysAsleep }
  private(set) var power = PowerState()

  // visibility (App+Visibility.swift)
  var coveredSince: [CGDirectDisplayID: Double] = [:]
  var dormant: Set<CGDirectDisplayID> = []
  var pendingStills: [CGDirectDisplayID: NSImage] = [:]
  var releasedAway = false
  var awayTimer: Timer?
  var coverTimer: Timer?

  var tunnelTimer: Timer?
  private var idleTimer: Timer?
  private var signalSources: [DispatchSourceSignal] = []
  private var atLogin = false
  var memBaseline: [Int: Double] = [:]   // each wall page process's size once settled (App+Memory)

  func applicationDidFinishLaunching(_ n: Notification) {
    atLogin = LoginItem.launchedAtLogin(NSAppleEventManager.shared().currentAppleEvent)   // (the launch event is current only now)
    if !benchMode { updater.launching() }
    startUsageMeter()
    if let a = argValue("--appearance") { NSApp.appearance = NSAppearance(named: a == "light" ? .aqua : .darkAqua) }
    handleTerminationSignals()
    #if TIDEWALL_DEV
    if args.contains("--ui-only") { return runWindowOnly() }
    SimInput.start()
    pretendDisplays()
    #endif
    buildWalls()
    startDesktopIcons()
    startTracking()
    startIdleWatch()
    observeSystem()
    #if TIDEWALL_DEV
    startDevHooks()
    if benchMode { return Bench.start(self) }
    #endif
    startAsApp()
  }

  func applicationWillTerminate(_ n: Notification) { walls.values.forEach { $0.close() } }

  func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows f: Bool) -> Bool {
    if !benchMode { appWindow.show() }
    return false
  }

  // MARK: start-up

  private func startUsageMeter() {
    usage.mark()
    let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.usage.mark() }
    t.tolerance = 5
    RunLoop.main.add(t, forMode: .common)
  }

  private func startDesktopIcons() {
    DeskIcons.shared = deskIcons
    deskIcons.onChange = { [weak self] in
      self?.sendDeskIcons()
      self?.retuneTunnel()
    }
    deskIcons.resting = { [weak self] in
      guard let self else { return true }
      return Tracker.idle || self.releasedAway
    }
    #if TIDEWALL_DEV
    pretendDesktopIcons()
    #endif
    deskIcons.start()
  }

  private func startTracking() {
    tracker.onUpdate = { [weak self] rects, live in
      guard let self else { return }
      lastRects = rects
      lastOwners = tracker.owners
      dispatch(live: live)
    }
    tracker.onCursor = { [weak self] p in
      guard let self else { return }
      let wall = walls.values.first { $0.cgFrame.contains(p) }
      // the pointer left a screen: its cursor effects fade out
      if let prev = cursorWall, prev !== wall { prev.send("{\"t\":\"cursorOff\"}") }
      cursorWall = wall
      if let wall, wall.paused == false { wall.cursor(p) }
    }
    tracker.start()
  }

  /// Nobody at the Mac (no mouse or key for Settings' idle minutes): every page rests until the first touch. Reading
  /// the system's input clock once a second needs no permission. The power source is checked every tenth tick.
  private func startIdleWatch() {
    let testLimit = argValue("--idletest").flatMap(Double.init)
    guard !benchMode || testLimit != nil else { return }
    var tick = 0
    idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      guard let self else { return }
      tick += 1
      if tick % 10 == 1 { checkPower() }
      let quiet = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
      memoryTick(tick, quiet: quiet)
      let limit = testLimit ?? Cfg.idleMinutes * 60
      let rest = limit > 0 && quiet > limit
      if rest != idleRest {
        idleRest = rest
        log(rest ? "idle: resting" : "input: awake")
        dispatch(live: false)
      }
    }
    idleTimer?.tolerance = 0.25                                        // a second, give or take: macOS can fold it in with other wake-ups
  }

  private func observeSystem() {
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
      self?.buildWalls()
      self?.appWindow.pushState()
      self?.appWindow.pushDesktop()
      self?.checkGPUContexts()
    }
    let workspace = NSWorkspace.shared.notificationCenter
    workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
      self?.displaysAsleep = true
      self?.dispatch(live: false)
      self?.updater.away()
    }
    workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
      self?.displaysAsleep = false
      self?.dispatch(live: false)
      self?.checkGPUContexts()
    }
    let distributed = DistributedNotificationCenter.default()
    distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
      self?.locked = true
      self?.dispatch(live: false)
      self?.updater.away()
    }
    distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
      self?.locked = false
      self?.dispatch(live: false)
      self?.checkGPUContexts()
    }
  }

  /// The real app (not a test run): login item, updates, the menu bar, and the window when opened by hand.
  private func startAsApp() {
    LoginItem.refresh()
    // relaunched by an update while the screen is locked: the lock notification came before us
    if let d = CGSessionCopyCurrentDictionary() as? [String: Any], d["CGSSessionScreenIsLocked"] as? Bool == true { locked = true }
    updater.onChange = { [weak self] in
      self?.statusMenu?.rebuild()
      self?.appWindow.pushState()
    }
    updater.isAway = { [weak self] in self?.asleep ?? false }
    updater.start()
    if Cfg.notesSeen == nil && !updater.justUpdated { Cfg.notesSeen = Cfg.version }   // a fresh install: nothing to announce
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.updater.cameUp() }
    if let from = argValue("--updated-from") { log("[update] updated from \(from) to \(Cfg.version)") }
    if !TestIsolation.on {
      DistributedNotificationCenter.default().addObserver(forName: .init("app.tidewall.show"), object: nil, queue: .main) { [weak self] _ in
        self?.appWindow.show()
      }
    }
    statusMenu = StatusMenu(app: self)
    statusMenu?.rebuild()
    if Bundle.main.bundleIdentifier == nil, let i = NSImage(contentsOf: themesRoot.appendingPathComponent("ui/icon.png")) {
      NSApp.applicationIconImage = i
    }
    buildMainMenu { [weak self] in self?.appWindow.show(page: "about") }
    if Mover.offerIfNeeded() { return }   // opened from Downloads: moves to Applications and reopens from there
    // opened by hand, not at login (or for the first time): show the window
    if !(args.contains("--background") || atLogin) || !Cfg.d.bool(forKey: "welcomed") {
      Cfg.d.set(true, forKey: "welcomed")
      appWindow.show()
    }
  }

  private func handleTerminationSignals() {
    for s in [SIGTERM, SIGINT] {
      signal(s, SIG_IGN)
      let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
      src.setEventHandler { NSApp.terminate(nil) }
      src.resume()
      signalSources.append(src)
    }
  }

  // MARK: power

  func checkPower() {
    let now = PowerState.current(), was = power
    power = now
    if now.onBattery != was.onBattery || now.lowPower != was.lowPower { appWindow.pushState() }
    if now.pace != was.pace {
      walls.values.forEach { $0.sendPace() }
      log("power: pages at \(now.pace == 1 ? "full" : "half") rate")
    }
    if now.paused != was.paused {
      log(now.paused ? "power: on battery, paused" : "power: running")
      dispatch(live: false)
    }
  }
}
