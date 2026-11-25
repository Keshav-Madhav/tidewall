import Cocoa
import ServiceManagement

/// Opening at login, as the app itself (SMAppService.mainApp): System Settings ▸ General ▸ Login Items lists Tidewall
/// under Open at Login, like any app you open at login. (Up to 1.4.0 it was a per-user LaunchAgent, which macOS files
/// under "Allow in the Background" with a background-items notice, as if it ran even after you quit: it never did.
/// An existing agent is swapped for this on the first launch after an update.)
enum LoginItem {
  /// (the app's own identifier: a test copy under another one only ever touches its own agent)
  static var label: String { Bundle.main.bundleIdentifier ?? "app.tidewall" }
  /// The agents from before: Driftland's, and Tidewall's own up to 1.4.0.
  static var oldPlists: [URL] { ["local.driftland", label].map { inHome("Library/LaunchAgents/\($0).plist") } }
  private static var service: SMAppService { SMAppService.mainApp }
  /// On (asked for), whether or not System Settings allows it.
  static var enabled: Bool { !TestIsolation.on && [.enabled, .requiresApproval].contains(service.status) }
  /// On, but switched off for Tidewall in System Settings ▸ General ▸ Login Items.
  static var blocked: Bool { !TestIsolation.on && service.status == .requiresApproval }

  /// At launch: an agent left by an older Tidewall becomes the login item (on stays on), and the agent goes.
  static func refresh() {
    guard !TestIsolation.on, Bundle.main.bundleIdentifier != nil else { return }
    let old = oldPlists.filter { FileManager.default.fileExists(atPath: $0.path) }
    guard !old.isEmpty else { return }
    // (launchd keeps the job it loaded at login until you log out: left alone, as removing it would stop this very app
    // when the agent started it. Until then it only restarts Tidewall after a crash; from the next login it's gone)
    old.forEach { try? FileManager.default.removeItem(at: $0) }
    // (an agent is there only while it's on)
    if let why = set(true) { log("login item: couldn't move to Open at Login: \(why)") } else { log("login item: the LaunchAgent is now an Open at Login item") }
  }

  /// Returns why it couldn't, if it couldn't.
  @discardableResult
  static func set(_ on: Bool) -> String? {
    // an isolated test copy leaves yours alone
    if TestIsolation.on { return nil }
    guard Bundle.main.bundleIdentifier != nil else { return "Only Tidewall.app can open at login (not a bare build)." }
    if !on {
      do { try service.unregister() } catch { if service.status != .notRegistered { return "Couldn't stop opening at login: \(error.localizedDescription)" } }
      return nil
    }
    // opened straight from Downloads, macOS runs the app from a temporary copy that is gone by the next login
    if Bundle.main.bundlePath.contains("/AppTranslocation/") { return "Move Tidewall to your Applications folder first, then turn this on." }
    do { try service.register() } catch {
      if service.status == .requiresApproval { return nil }   // on, waiting for System Settings: shown as blocked
      return "Couldn't set up opening at login: \(error.localizedDescription)"
    }
    return nil
  }

  /// For `--login-item-status`: what macOS says, and when you signed in.
  static var status: String {
    let s: String
    switch service.status { case .enabled: s = "on"; case .requiresApproval: s = "on, waiting for System Settings"; case .notRegistered: s = "off"; case .notFound: s = "not found"; @unknown default: s = "?" }
    return "\(label): \(s); signed in at the console \(consoleLogin.map { "\($0)" } ?? "?"); old agents left: \(oldPlists.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.lastPathComponent))"
  }

  /// Whether this launch is the one at login (so no window): macOS says so in the launch event, and, should it not,
  /// a launch within three minutes of signing in at the console counts.
  static func launchedAtLogin(_ event: NSAppleEventDescriptor?) -> Bool {
    if let e = event, e.eventID == kAEOpenApplication,
       e.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem { return true }
    guard enabled, let since = consoleLogin else { return false }
    return Date().timeIntervalSince(since) < 180
  }

  /// When you signed in at the console (this session), from the login records.
  private static var consoleLogin: Date? {
    setutxent(); defer { endutxent() }
    var latest: Date?
    while let p = getutxent() {
      let u = p.pointee
      guard u.ut_type == USER_PROCESS else { continue }
      let line = withUnsafeBytes(of: u.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
      let user = withUnsafeBytes(of: u.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
      guard line == "console", user == NSUserName() else { continue }
      let t = Date(timeIntervalSince1970: TimeInterval(u.ut_tv.tv_sec))
      if latest.map({ t > $0 }) ?? true { latest = t }
    }
    return latest
  }

  private static func inHome(_ path: String) -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path)
  }
}
