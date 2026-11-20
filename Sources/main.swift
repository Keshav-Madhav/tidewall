import Cocoa
import Darwin

func log(_ s: String) {
  print(s)
  fflush(stdout)
}

if let v = argValue("--fps").flatMap(Double.init) { Cfg.fps = v }
if let v = argValue("--variant") { Cfg.variantOverride = v }
if let v = argValue("--theme") { Cfg.themeOverride = v }
if let v = argValue("--margin").flatMap(Double.init) { Cfg.margin = v }
Cfg.migrate()
if !benchMode { Cfg.resetInheritedFrameRate() }
runPrintCommands()

keepLogFile()

// AppKit catches exceptions thrown while it handles a click or a menu, logs them and carries on in whatever state they
// left behind. Crash on them instead, so they reach the log (and the system's report) like any other crash.
UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
NSSetUncaughtExceptionHandler { e in
  let stack = e.callStackSymbols.prefix(40).joined(separator: "\n")
  log("CRASH exception \(e.name.rawValue): \(e.reason ?? "") (Tidewall \(Cfg.version))\n" + stack)
}

// A crash signal logs its stack. Memory may be corrupt by then, so all the handler touches is made here and it allocates
// nothing; it then returns (SA_RESETHAND), the faulting instruction runs again, and the process dies of the original fault.
let crashHead: UnsafeMutablePointer<CChar> = strdup("CRASH signal (Tidewall); stack:\n")
let crashFrames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)
_ = backtrace(crashFrames, 64)   // loads what backtrace needs now, not mid-crash
do {
  var alt = stack_t()
  alt.ss_size = 1 << 16
  alt.ss_sp = UnsafeMutableRawPointer.allocate(byteCount: 1 << 16, alignment: 16)
  alt.ss_flags = 0
  sigaltstack(&alt, nil)   // a stack overflow still gets its log line
  for sig in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
    var sa = sigaction()
    sa.__sigaction_u.__sa_handler = { _ in
      _ = write(STDOUT_FILENO, crashHead, strlen(crashHead))
      backtrace_symbols_fd(crashFrames, backtrace(crashFrames, 64), STDOUT_FILENO)
    }
    sa.sa_flags = SA_RESETHAND | SA_ONSTACK
    sigaction(sig, &sa, nil)
  }
}

if !benchMode && !TestIsolation.on && !args.contains("--ui-only"), let id = Bundle.main.bundleIdentifier {
  settleWithOtherCopies(of: id)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

// MARK: start-up steps

/// Development probes that print something and exit.
private func runPrintCommands() {
  if args.contains("--print-site") {
    print(Cfg.site.map { "\($0.name) \($0.lat),\($0.lon) \($0.cc)" } ?? "none", Cfg.homeRegion ?? "-")
    exit(0)
  }
  if args.contains("--print-report") {
    print(ProblemReport.clipboardText())
    print("---- issue URL ----\n" + ProblemReport.issueURL().absoluteString)
    exit(0)
  }
  if args.contains("--install-login-item") {
    LoginItem.set(true)
    print(LoginItem.plist.path)
    exit(0)
  }
}

/// The released app always logs to ~/Library/Logs/Tidewall.log (opened from Finder, stdout goes nowhere); past 5 MB it
/// starts over.
private func keepLogFile() {
  if Bundle.main.bundleIdentifier != nil && !benchMode && !stdoutIsAFile() {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let name = TestIsolation.on ? "Tidewall-isolated-test.log" : "Tidewall.log"
    // opened first and swapped in only if that worked: a failed freopen would leave fd 1 free for whatever opens next
    let fd = open(dir.appendingPathComponent(name).path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    if fd >= 0 {
      fflush(stdout)
      dup2(fd, STDOUT_FILENO)
      dup2(fd, STDERR_FILENO)
      close(fd)
    }
  }
  if let st = stdoutStat(), st.st_size > 5_000_000, (st.st_mode & S_IFMT) == S_IFREG { ftruncate(STDOUT_FILENO, 0) }
}

private func stdoutStat() -> stat? {
  var st = stat()
  return fstat(STDOUT_FILENO, &st) == 0 ? st : nil
}

private func stdoutIsAFile() -> Bool {
  guard let st = stdoutStat() else { return false }
  return (st.st_mode & S_IFMT) == S_IFREG
}

/// One Tidewall at a time: opening a second copy shows the running one's window instead, unless this copy is newer (an
/// update downloaded by hand). Then the old one is asked to quit and this one carries on.
private func settleWithOtherCopies(of id: String) {
  let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != getpid() }
  guard !others.isEmpty else { return }
  guard others.allSatisfy({ Updater.newer(Cfg.version, than: bundleVersion($0)) }) else {
    DistributedNotificationCenter.default().postNotificationName(.init("app.tidewall.show"), object: nil, userInfo: nil,
                                                                 deliverImmediately: true)
    exit(0)
  }
  log("[launch] replacing the running Tidewall \(others.map(bundleVersion).joined(separator: ", ")) with \(Cfg.version)")
  others.forEach { _ = $0.terminate() }
  let until = Date().addingTimeInterval(8)
  while others.contains(where: { !$0.isTerminated }) && Date() < until {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
  }
  others.filter { !$0.isTerminated }.forEach { _ = $0.forceTerminate() }
}

private func bundleVersion(_ a: NSRunningApplication) -> String {
  let plist = a.bundleURL.flatMap { NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist")) }
  return plist?["CFBundleShortVersionString"] as? String ?? "0"
}
