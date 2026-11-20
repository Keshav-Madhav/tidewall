import Foundation

@discardableResult
func runTool(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
  let process = Process()
  let pipe = Pipe()
  process.executableURL = URL(fileURLWithPath: tool)
  process.arguments = arguments
  process.standardOutput = pipe
  process.standardError = pipe
  do {
    try process.run()
  } catch {
    return (-1, "")
  }
  let output = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return (process.terminationStatus, String(data: output, encoding: .utf8) ?? "")
}

/// Runs a /bin/sh script that outlives this process: its own session (so launchd tidying up the login item's process
/// group can't take it down) and a clean environment (nothing of ours leaks into whatever it opens).
func spawnDetached(_ script: String) -> Bool {
  var attr: posix_spawnattr_t? = nil
  posix_spawnattr_init(&attr)
  posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
  var pid: pid_t = 0
  let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(script), nil]
  let environment = [
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
    "HOME=\(NSHomeDirectory())",
    "USER=\(NSUserName())",
    "TMPDIR=\(NSTemporaryDirectory())",
  ]
  let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
  let rc = posix_spawn(&pid, "/bin/sh", nil, &attr, argv, envp)
  posix_spawnattr_destroy(&attr)
  argv.forEach { free($0) }
  envp.forEach { free($0) }
  return rc == 0
}

func shQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
