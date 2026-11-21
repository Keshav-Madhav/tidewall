import Cocoa

/// Keeps Tidewall up to date from its GitHub releases, without an Apple Developer ID. Each release's update.json is
/// Ed25519-signed (tools/update-sign.swift) and nothing in it is used until that checks out; the download is checked
/// again (size, SHA-256, signature, bundle id, version, code signature), unpacked beside the app, and swapped in with
/// plain renames by a detached helper that puts the old copy back if the new one doesn't come up.
/// Development builds never update themselves, and only they honour the TIDEWALL_UPDATE_* test variables.
final class Updater {
  enum State: Equatable {
    case idle, checking, downloading(String), ready(String), blocked(String, String), skipped(String), upToDate
    case failed(String), off(String)
  }

  private enum Staged {
    case ok(URL, String)
    case bad(String)
  }

  #if TIDEWALL_DEV
  static let devBuild = true
  #else
  static let devBuild = false
  #endif
  static let env: [String: String] =
    devBuild ? ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("TIDEWALL_UPDATE_") } : [:]
  /// The release-signing keys' public halves: the one CI signs with, and an offline backup (kept off GitHub) in case the
  /// first is ever lost or retired. Removing a key strands installs that only trust it.
  static let publicKeys = ["jjgDHnSJpmtt4178OEDmCcY5tCnQ3yryG8fnEPBxvyE=", "KsHXWESHYkG6q4hV1qc6fYixqZj5UcoS/34N+7Gwycw="]
  /// Plus, in development builds, a throwaway key for signing local test releases (TIDEWALL_UPDATE_TESTKEY).
  static var trustedKeys: [String] { publicKeys + (env["TIDEWALL_UPDATE_TESTKEY"].map { [$0] } ?? []) }
  static let feed = URL(string: env["TIDEWALL_UPDATE_FEED"] ?? "https://github.com/Keshav-Madhav/tidewall/releases/latest/download/update.json")!
  static let releasesPage = URL(string: "https://github.com/Keshav-Madhav/tidewall/releases/latest")!

  private static var testFeed: Bool { env["TIDEWALL_UPDATE_FEED"] != nil }
  /// An administrator's install, walked without one (tools/update-test.sh): the script goes through AppleScript's
  /// quoting, must come out byte for byte, and then runs as you.
  private static var adminDryRun: Bool { env["TIDEWALL_UPDATE_ADMIN_DRYRUN"] == "1" }

  static func mayDownload(_ url: URL) -> Bool { url.scheme == "https" || testFeed }

  private(set) var state = State.idle {
    didSet { if state != oldValue { onChange?() } }
  }
  var onChange: (() -> Void)?
  var isAway: () -> Bool = { false }
  private(set) var justUpdated = args.contains("--updated-from")

  private var staged: URL?
  private var stagedHash = ""
  private var lastCheck: Date?
  private var timer: Timer?
  private var notes = ""

  private let fm = FileManager.default
  private let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent(TestIsolation.on ? "app.tidewall.isolated-test" : "app.tidewall")
  private var dl: URL { caches.appendingPathComponent("update") }
  private var alive: URL { caches.appendingPathComponent("update-alive") }
  private var result: URL { caches.appendingPathComponent("update-result") }
  private var pidFile: URL { caches.appendingPathComponent("update-pid") }

  /// Beside the app, so every step of the swap is a rename on one volume (in caches when it needs an administrator).
  private var work: URL {
    if needsAdmin { return caches.appendingPathComponent("stage") }
    return Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(".tidewall-update-\(getuid())")
  }

  /// The app's folder isn't writable by this account: updates still download, and installing asks for a password.
  var needsAdmin: Bool { !fm.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path) }

  /// Why updates are off altogether (nil: they're on).
  var off: String? { Self.devBuild && !Self.testFeed ? "This is a development build; it doesn't update itself." : nil }

  /// Only a copy macOS runs from a temporary place (opened straight from Downloads) can't replace itself.
  var cantInstall: String? {
    Bundle.main.bundleURL.path.contains("/AppTranslocation/") ? "Move Tidewall to your Applications folder to get updates." : nil
  }

  // MARK: lifecycle

  /// First thing at launch: this copy's pid, so an install's helper can stop exactly this process if it hangs.
  func launching() {
    try? fm.createDirectory(at: caches, withIntermediateDirectories: true)
    try? "\(getpid())".write(to: pidFile, atomically: true, encoding: .utf8)
  }

  /// The wallpapers are up: an install's helper waits for this before it lets go of the previous copy.
  func cameUp() {
    #if TIDEWALL_DEV
    if Bundle.main.object(forInfoDictionaryKey: "TidewallTestNeverAlive") as? Bool == true { return }   // update-test.sh's broken release
    #endif
    try? Cfg.version.write(to: alive, atomically: true, encoding: .utf8)
    // the helper records the outcome only once it has seen this: read it this launch, not the next
    if args.contains("--updated-from") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.readLastInstall() }   // (it polls 5× a second)
    }
  }

  func start() {
    readLastInstall()
    DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in self?.clearLeftovers() }
    if let why = off {
      state = .off(why)
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + (Self.testFeed ? 8 : 45)) { [weak self] in self?.check(manual: false) }
    timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check(manual: false) }
  }

  private func readLastInstall() {
    guard let text = try? String(contentsOf: result, encoding: .utf8) else { return }
    let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
    if parts.count == 2, parts[0] != "ok" {
      recordFailure(parts[1])
      log("[update] installing \(parts[1]) didn't work (\(parts[0])); keeping \(Cfg.version)")
    } else if parts.count == 2 {
      log("[update] \(parts[1]) installed")
      justUpdated = true
    }
    try? fm.removeItem(at: result)
  }

  /// Leftovers of an earlier update: 25 s in, any install helper has seen update-alive and let go of them. Not if this
  /// copy never reported in: a helper is then still waiting to put the previous copy (parked in `work`) back.
  private func clearLeftovers() {
    guard staged == nil, (try? String(contentsOf: alive, encoding: .utf8)) == Cfg.version else { return }
    switch state {
    case .checking, .downloading, .ready:
      return
    default:
      break
    }
    try? fm.removeItem(at: work)
    try? fm.removeItem(at: dl)
    try? fm.removeItem(at: alive)
    try? fm.removeItem(at: pidFile)
    try? fm.removeItem(at: caches.appendingPathComponent("update-install.sh"))   // (1.2.7 and earlier wrote one)
  }

  private func recordFailure(_ v: String) {
    var failures = Cfg.d.dictionary(forKey: "update.failed") as? [String: Int] ?? [:]
    failures[v, default: 0] += 1
    Cfg.d.set(failures, forKey: "update.failed")
  }

  /// A version that failed twice waits for a newer one (once could be bad luck: a busy Mac, a lid closed mid-install).
  private func hasFailed(_ v: String) -> Bool {
    ((Cfg.d.dictionary(forKey: "update.failed") as? [String: Int])?[v] ?? 0) > 1
  }

  /// Where things stand, for the app window.
  var status: [String: Any] {
    let fields: [String: Any]
    switch state {
    case .idle: fields = ["s": "idle"]
    case .checking: fields = ["s": "checking"]
    case .downloading(let v): fields = ["s": "downloading", "v": v]
    case .ready(let v): fields = ["s": "ready", "v": v, "notes": notes]
    case .blocked(let v, let why): fields = ["s": "ready", "v": v, "blocked": why, "notes": notes]
    case .upToDate: fields = ["s": "current"]
    case .skipped(let v): fields = ["s": "skipped", "v": v]
    case .failed(let e): fields = ["s": "failed", "err": e]
    case .off(let why): fields = ["s": "off", "err": why]
    }
    var o: [String: Any] = ["auto": Cfg.autoUpdate, "admin": needsAdmin].merging(fields) { $1 }
    if let d = lastCheck { o["checked"] = Int(d.timeIntervalSince1970) }
    return o
  }

  static func newer(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }
    let y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) {
      let p = i < x.count ? x[i] : 0
      let q = i < y.count ? y[i] : 0
      if p != q { return p > q }
    }
    return false
  }

  // MARK: checking

  func check(manual: Bool, fromWindow: Bool = false) {
    if let why = off {
      state = .off(why)
      if manual { tell("Updates are off", why) }
      return
    }
    switch state {
    case .checking, .downloading:
      return
    case .ready(let v):
      if manual { tell("Tidewall \(v) is ready", "Choose “Restart to Update to \(v)” in the menu bar.") }
      return
    default:
      break
    }
    guard manual || fromWindow || Cfg.autoUpdate else { return }
    state = .checking
    var request = URLRequest(url: Self.feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    request.setValue("Tidewall/\(Cfg.version)", forHTTPHeaderField: "User-Agent")
    URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      DispatchQueue.main.async {
        self?.received(data, response, error, manual: manual, fromWindow: fromWindow)
      }
    }.resume()
  }

  private func received(_ data: Data?, _ response: URLResponse?, _ error: Error?, manual: Bool, fromWindow: Bool) {
    lastCheck = Date()
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard error == nil, code == 200, let data,
          let feed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let release = Release(feed: feed) else {
      let why = error?.localizedDescription
        ?? (code == 404 ? "no update information was found"
            : code == 200 ? "the update information couldn’t be read" : "the update feed answered \(code)")
      log("[update] check failed: \(why)")
      state = .failed(why)
      if manual {
        tell("Couldn’t check for updates", "\(why.prefix(1).uppercased() + why.dropFirst()). You have version \(Cfg.version).")
      }
      return
    }
    // nothing in the feed is trusted until its signature checks out (the zip itself is checked again after download)
    guard release.isSigned else {
      log("[update] the update feed's signature is invalid; ignoring it")
      state = .failed("the update information isn't signed by Tidewall")
      if manual { tell("Couldn’t check for updates", "The update information wasn’t signed by Tidewall.") }
      return
    }
    let v = release.version
    let minOS = release.minOS
    let os = ProcessInfo.processInfo.operatingSystemVersion
    guard Self.newer(v, than: Cfg.version) else {
      state = .upToDate
      if manual { tell("Tidewall is up to date", "You have version \(Cfg.version), the newest.") }
      return
    }
    guard !Self.newer(minOS, than: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)") else {
      state = .failed("Tidewall \(v) needs macOS \(minOS)")
      if manual { tell("Tidewall \(v) needs macOS \(minOS)", "This Mac stays on \(Cfg.version).") }
      return
    }
    guard Self.mayDownload(release.url) else {
      state = .failed("insecure update URL")
      return
    }
    notes = release.notes   // plain text: never render it as HTML
    if let why = cantInstall {
      state = .blocked(v, why)
      if manual { tell("Tidewall \(v) is available", "\(why) Choose “Move to Applications” in Tidewall ▸ About.") }
      return
    }
    let patch = release.patch(in: feed)
    if !manual && !fromWindow && hasFailed(v) {
      log("[update] \(v) failed to install twice; waiting for a newer one (or Check for Updates…)")
      state = .skipped(v)
      return
    }
    log("[update] \(v) is available (have \(Cfg.version)); downloading")
    if manual {
      tell("Tidewall \(v) is available", "It’s downloading now. When it’s ready, choose “Restart to Update” in the menu bar.")
    }
    if let patch {
      downloadPatch(v, patch.patch, cdhash: patch.cdhash) { ok in
        if !ok { self.download(release) }
      }
    } else {
      download(release)
    }
  }

  // MARK: downloading

  /// done(false) when the patched copy isn't exactly the release: the whole release is fetched instead.
  private func downloadPatch(_ v: String, _ patch: Release.Patch, cdhash: String, done: @escaping (Bool) -> Void) {
    state = .downloading(v)
    log("[update] \(v): fetching only what changed since \(patch.from) (\(patch.size / 1000) KB)")
    URLSession.shared.downloadTask(with: patch.url) { [weak self] file, response, error in
      guard let self else { return }
      let outcome = Self.staging(file, response, error) { self.stagePatch($0, v, patch, cdhash: cdhash) }
      DispatchQueue.main.async {
        switch outcome {
        case .ok(let app, let hash):
          self.hold(app, hash, v)
          log("[update] \(v) is ready to install (patched)")
          self.away()
          done(true)
        case .bad(let why):
          log("[update] the \(v) patch didn't work (\(why)); fetching the whole release")
          done(false)
        }
      }
    }.resume()
  }

  private func download(_ release: Release) {
    let v = release.version
    state = .downloading(v)
    URLSession.shared.downloadTask(with: release.url) { [weak self] file, response, error in
      guard let self else { return }
      // verified and unpacked off the main thread: hashing ~130 MB takes a moment
      let outcome = Self.staging(file, response, error) { self.verifyAndStage($0, release) }
      DispatchQueue.main.async {
        switch outcome {
        case .ok(let app, let hash):
          self.hold(app, hash, v)
          log("[update] \(v) is ready to install")
          self.away()
        case .bad(let why):
          log("[update] \(v) rejected: \(why)")
          self.state = .failed(why)
        }
      }
    }.resume()
  }

  private static func staging(_ file: URL?, _ response: URLResponse?, _ error: Error?, _ stage: (URL) -> Staged) -> Staged {
    guard let file, error == nil, (response as? HTTPURLResponse)?.statusCode == 200 else {
      return .bad(error?.localizedDescription ?? "download failed")
    }
    return stage(file)
  }

  private func hold(_ app: URL, _ hash: String, _ v: String) {
    staged = app
    stagedHash = hash
    state = .ready(v)
  }

  private func emptyStage(for v: String) -> URL {
    let stage = work.appendingPathComponent(v)
    try? fm.removeItem(at: stage)
    try? fm.createDirectory(at: stage, withIntermediateDirectories: true)
    return stage
  }

  private func stagePatch(_ zip: URL, _ v: String, _ patch: Release.Patch, cdhash: String) -> Staged {
    if let why = BundleCheck.mismatch(zip, size: patch.size, sha: patch.sha) { return .bad(why) }
    let stage = emptyStage(for: v)
    let app = stage.appendingPathComponent("Tidewall.app")
    // this copy, cloned (on APFS: instant, and no extra space until files differ)
    let here = Bundle.main.bundleURL.path
    let cloned = runTool("/bin/cp", ["-cR", here, app.path]).status == 0 || runTool("/usr/bin/ditto", [here, app.path]).status == 0
    guard cloned else { return .bad("couldn't copy the app") }
    guard runTool("/usr/bin/ditto", ["-x", "-k", zip.path, stage.path]).status == 0 else {
      return .bad("couldn't unpack the patch")
    }
    removeDeletedFiles(listedIn: stage.appendingPathComponent("deleted.txt"), from: app)
    guard BundleCheck.isTidewall(app, version: v) else { return .bad("the patched copy isn't Tidewall \(v)") }
    runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
    guard let hash = BundleCheck.codeHash(app), hash.lowercased() == "cdhash=" + cdhash.lowercased() else {
      try? fm.removeItem(at: stage)
      return .bad("the patched copy isn't exactly the release")
    }
    return .ok(app, hash)
  }

  /// The files the release dropped, as paths inside the bundle; anything absolute or climbing out is ignored.
  private func removeDeletedFiles(listedIn list: URL, from app: URL) {
    if let text = try? String(contentsOf: list, encoding: .utf8) {
      let lines = text.split(separator: "\n").map(String.init)
      for line in lines where !line.isEmpty && !line.hasPrefix("/") && !line.split(separator: "/").contains("..") {
        try? fm.removeItem(at: app.appendingPathComponent(line))
      }
    }
    try? fm.removeItem(at: list)
  }

  private func verifyAndStage(_ zip: URL, _ release: Release) -> Staged {
    let v = release.version
    if let why = BundleCheck.mismatch(zip, size: release.size, sha: release.sha) { return .bad(why) }
    guard release.isSigned else { return .bad("bad signature: not a Tidewall release") }
    let stage = emptyStage(for: v)
    guard runTool("/usr/bin/ditto", ["-x", "-k", zip.path, stage.path]).status == 0 else {
      return .bad("couldn't unpack the update")
    }
    let app = stage.appendingPathComponent("Tidewall.app")
    guard BundleCheck.isTidewall(app, version: v) else { return .bad("the update isn't Tidewall \(v)") }
    runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
    guard let hash = BundleCheck.codeHash(app) else { return .bad("the update's code signature is broken") }
    return .ok(app, hash)
  }

  // MARK: installing

  /// The screen locked or the displays slept: install now if updates are automatic, unless it needs a password or failed.
  func away() {
    guard case .ready(let v) = state, Cfg.autoUpdate, cantInstall == nil, !needsAdmin, !hasFailed(v),
          isAway() || Self.env["TIDEWALL_UPDATE_INSTALL_NOW"] == "1" else { return }
    log("[update] installing while you're away")
    install()
  }

  func install() {
    if case .blocked = state {
      if !Mover.moveNow() { NSWorkspace.shared.open(Self.releasesPage) }
      return
    }
    guard case .ready(let v) = state, let new = staged else { return }
    if let why = cantInstall {
      tell("Can’t update here", why)
      return
    }
    // the unpacked copy waited, maybe for hours: make sure it's exactly what was verified
    guard BundleCheck.codeHash(new) == stagedHash, !stagedHash.isEmpty else {
      log("[update] the downloaded \(v) changed since it was checked; discarding it")
      staged = nil
      try? fm.removeItem(at: work)
      state = .failed("the downloaded update changed; it will be fetched again")
      return
    }
    let previous = work.appendingPathComponent("previous.app").path
    let admin = needsAdmin || Self.adminDryRun
    let script = InstallScript(new: new, previous: previous, alive: alive, result: result, pidFile: pidFile, version: v,
                               hash: stagedHash, privateCopy: admin).text
    if admin {
      guard runAsAdministrator(script, v) else { return }
    } else {
      guard spawnDetached(script) else {
        log("[update] couldn't start the installer")
        state = .failed("couldn't start the installer")
        return
      }
    }
    log("[update] installing \(v); relaunching")
    NSApp.terminate(nil)
  }

  /// macOS asks for an administrator's password, then the helper runs as root. The script goes to it as text, never
  /// as a file: a file this account can write could be changed between the password and the run. False when it didn't
  /// start.
  private func runAsAdministrator(_ script: String, _ v: String) -> Bool {
    let aq = { (s: String) in
      "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
    let prompt = "Tidewall wants to install version \(v). It needs an administrator’s permission because of where it’s installed."
    let source = "do shell script \"/bin/sh -c \" & quoted form of \(aq(script)) & \" >/dev/null 2>&1 &\" with prompt \(aq(prompt)) with administrator privileges"
    #if TIDEWALL_DEV
    if Self.adminDryRun {
      var error: NSDictionary?
      let roundTrip = NSAppleScript(source: "return \(aq(script))")?.executeAndReturnError(&error).stringValue
      log("[update] administrator dry run: the script \(roundTrip == script ? "survives" : "does NOT survive") AppleScript's quoting")
      return roundTrip == script && spawnDetached(script)
    }
    #endif
    NSApp.activate(ignoringOtherApps: true)
    var error: NSDictionary?
    _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
    guard let error else { return true }
    let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
    log("[update] the installer wasn't allowed to run (\(code))")
    if code != -128 { tell("Couldn’t install the update", "\(error[NSAppleScript.errorMessage] ?? "macOS didn’t allow it.")") }
    return false
  }

  private func tell(_ title: String, _ body: String) {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = body
    alert.icon = NSApp.applicationIconImage
    alert.runModal()
  }
}
