import Cocoa

/// Opened from Downloads (or anywhere outside an Applications folder), Tidewall offers once to move itself there:
/// only from there can it open at login and update itself. Until a downloaded app is moved, macOS runs it from a
/// temporary read-only copy (App Translocation), so the original is found through the Security framework.
enum Mover {
  /// About ▸ Move to Applications (a copy macOS runs from Downloads can't update itself): move it now, no question.
  static func moveNow() -> Bool { offerIfNeeded(force: true) }

  /// True when it's moving: this copy then quits and the moved one opens.
  static func offerIfNeeded(force: Bool = false) -> Bool {
    let noQuestion = force || Updater.env["TIDEWALL_UPDATE_MOVE_TEST"] == "1"
    guard force || !args.contains("--moved"), force || !Updater.devBuild || noQuestion else { return false }
    let src = original
    // Already in Applications but run from a translocated copy (unzipped there rather than moved by Finder): clear the
    // quarantine flag you've already approved and open the real one, once.
    if inApplications(src) {
      guard src != Bundle.main.bundleURL else { return false }
      unquarantine(src)
      log("[move] reopening \(src.path) from where it is")
      return relaunch(src)
    }
    guard noQuestion || !Cfg.d.bool(forKey: "moveDeclined") else { return false }
    let apps = applicationsFolder()
    let dest = apps.appendingPathComponent("Tidewall.app")
    // already installed and at least as new (say an old download opened by mistake): open that, never downgrade it
    if let have = infoValue("CFBundleShortVersionString", of: dest), !Updater.newer(Cfg.version, than: have) {
      log("[move] Tidewall \(have) is already in \(apps.path); opening that")
      return relaunch(dest)
    }
    if !noQuestion && !askToMove() {
      Cfg.d.set(true, forKey: "moveDeclined")
      return false
    }
    do {
      try copy(src, to: dest, in: apps)
    } catch {
      // so it doesn't ask at every launch; Settings ▸ Updates explains
      Cfg.d.set(true, forKey: "moveDeclined")
      let alert = NSAlert()
      alert.messageText = "Couldn’t move Tidewall"
      alert.informativeText = error.localizedDescription
      alert.runModal()
      return false
    }
    // you've opened it once already (Gatekeeper is done with it): no second translocation
    unquarantine(dest)
    try? FileManager.default.trashItem(at: src, resultingItemURL: nil)
    log("[move] moved to \(dest.path)")
    return relaunch(dest)
  }

  /// Where the app really is, not the translocated copy it's running from.
  private static var original: URL {
    let running = Bundle.main.bundleURL
    guard running.path.contains("/AppTranslocation/"),
          let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
          let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return running }
    typealias CreateOriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
    let createOriginalPath = unsafeBitCast(symbol, to: CreateOriginalPath.self)
    return (createOriginalPath(running as CFURL, nil)?.takeRetainedValue() as URL?) ?? running
  }

  private static func inApplications(_ app: URL) -> Bool {
    let parent = app.deletingLastPathComponent().path
    return ["/Applications", NSHomeDirectory() + "/Applications"].contains { parent == $0 || parent.hasPrefix($0 + "/") }
  }

  private static func applicationsFolder() -> URL {
    if let testDest = Updater.env["TIDEWALL_UPDATE_MOVE_DEST"] { return URL(fileURLWithPath: testDest) }
    let fm = FileManager.default
    if fm.isWritableFile(atPath: "/Applications") { return URL(fileURLWithPath: "/Applications") }
    return fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
  }

  private static func infoValue(_ key: String, of app: URL) -> String? {
    NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?[key] as? String
  }

  private static func askToMove() -> Bool {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.icon = NSApp.applicationIconImage
    alert.messageText = "Move Tidewall to your Applications folder?"
    alert.informativeText = "From there it can open when you log in and keep itself up to date. You only do this once."
    alert.addButton(withTitle: "Move to Applications")
    alert.addButton(withTitle: "Not Now")
    return alert.runModal() == .alertFirstButtonReturn
  }

  private static func copy(_ src: URL, to dest: URL, in apps: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: apps, withIntermediateDirectories: true)
    if fm.fileExists(atPath: dest.path) {
      guard infoValue("CFBundleIdentifier", of: dest) == "app.tidewall" else {
        let message = "Something else called Tidewall.app is already in \(apps.path)."
        throw NSError(domain: "Tidewall", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
      }
      try fm.trashItem(at: dest, resultingItemURL: nil)
    }
    try fm.copyItem(at: src, to: dest)
  }

  /// Opens `app` once this copy has quit; --moved stops the opened copy from offering to move again.
  private static func relaunch(_ app: URL) -> Bool {
    let script = "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \(shQuote(app.path)) --args --moved"
    guard spawnDetached(script) else { return false }
    NSApp.terminate(nil)
    return true
  }

  private static func unquarantine(_ app: URL) {
    runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
  }
}
