import Cocoa
import ServiceManagement

/// Opening at login, as a per-user LaunchAgent: it starts at login, restarts after a crash, and stays quit when you quit.
enum LoginItem {
  static let label = "app.tidewall"
  /// The agent from before the rename to Tidewall.
  static var oldPlist: URL { inHome("Library/LaunchAgents/local.driftland.plist") }
  static var plist: URL { inHome("Library/LaunchAgents/\(label).plist") }
  static var enabled: Bool { FileManager.default.fileExists(atPath: plist.path) }
  /// On, but switched off for Tidewall in System Settings ▸ General ▸ Login Items.
  static var blocked: Bool { enabled && SMAppService.statusForLegacyPlist(at: plist) == .requiresApproval }

  /// The app was moved (say into /Applications) since the login item was made: point it at where the app is now.
  static func refresh() {
    guard !TestIsolation.on, enabled, Bundle.main.bundleIdentifier != nil,
          let agent = NSDictionary(contentsOf: plist), let arguments = agent["ProgramArguments"] as? [String],
          let first = arguments.first, first != executable else { return }
    set(true)
    log("login item: now opens \(CommandLine.arguments[0])")
  }

  /// Returns why it couldn't, if it couldn't.
  @discardableResult
  static func set(_ on: Bool) -> String? {
    // an isolated test copy leaves yours alone
    if TestIsolation.on { return nil }
    try? FileManager.default.removeItem(at: oldPlist)
    if !on {
      try? FileManager.default.removeItem(at: plist)
      return nil
    }
    let exe = executable
    // opened straight from Downloads, macOS runs the app from a temporary copy that is gone by the next login
    if exe.contains("/AppTranslocation/") { return "Move Tidewall to your Applications folder first, then turn this on." }
    let job = agent(running: exe)
    do {
      try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
      try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: plist)
    } catch {
      return "Couldn't set up opening at login: \(error.localizedDescription)"
    }
    return nil
  }

  private static func agent(running exe: String) -> [String: Any] {
    let logPath = inHome("Library/Logs/Tidewall.log").path
    let arguments = argValue("--themes") != nil ? [exe, "--background", "--themes", themesRoot.path] : [exe, "--background"]
    return [
      "Label": label,
      "ProgramArguments": arguments,
      "RunAtLoad": true,
      "KeepAlive": ["SuccessfulExit": false],
      "ProcessType": "Interactive",
      "StandardOutPath": logPath,
      "StandardErrorPath": logPath,
    ]
  }

  private static var executable: String {
    URL(fileURLWithPath: CommandLine.arguments[0]).standardized.resolvingSymlinksInPath().path
  }

  private static func inHome(_ path: String) -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path)
  }
}
