import Cocoa
import WebKit

/// A wall's page process holding far more memory than it settled at gets a fresh one. A page that rebuilt itself many
/// times (a world laid out across displays, screens covered and uncovered, an update) once kept 240 MB of freed arrays
/// it never gave back; rebuilding the pages in a process lets WebKit start a clean one (what switching modes did by
/// hand). Checked every five minutes against the process's own size once it settled, and done only at a quiet moment
/// (a minute without mouse or keys), with the usual hand-over: each display keeps its picture until the new page draws.
extension App {
  /// From the idle watch, once a second; `quiet` is seconds since the last input.
  func memoryTick(_ tick: Int, quiet: Double) {
    let test = Self.memTest
    let every = test?.every ?? 300
    guard tick % Int(every) == 0, !walls.isEmpty, !releasedAway else { return }
    var byPid: [Int: [CGDirectDisplayID]] = [:]
    for (id, w) in walls where w.ready { let p = webPid(w.web); if p > 0 { byPid[p, default: []].append(id) } }
    let now = ProcessInfo.processInfo.systemUptime
    for (pid, ids) in byPid {
      guard let mb = footprintMB(pid_t(pid)) else { continue }
      // the baseline: the process's size once every page in it has been showing for two minutes (settled after start-up)
      guard let base = memBaseline[pid] else {
        if ids.allSatisfy({ walls[$0].flatMap(\.seenSince).map { now - $0 > (test == nil ? 120 : 5) } ?? false }) {
          memBaseline[pid] = mb
          log(String(format: "memory: page process %d settled at %.0f MB", pid, mb))
        }
        continue
      }
      let limit = base + max(test?.mb ?? 250, test == nil ? base * 0.8 : 0)
      guard mb > limit, test != nil || quiet > 60 else { continue }
      log(String(format: "memory: page process %d at %.0f MB (settled at %.0f): fresh pages for %d display(s)", pid, mb, base, ids.count))
      memBaseline[pid] = nil
      freshPages(ids)
    }
    memBaseline = memBaseline.filter { byPid[$0.key] != nil }   // (processes that went away)
  }

  /// --memwatch EVERY,MB (development): check every EVERY seconds, rebuild past settled + MB, without waiting for quiet.
  static let memTest: (every: Double, mb: Double)? = {
    #if TIDEWALL_DEV
    guard let v = argValue("--memwatch")?.split(separator: ","), v.count == 2, let e = Double(v[0]), let m = Double(v[1]) else { return nil }
    return (e, m)
    #else
    return nil
    #endif
  }()

  private func footprintMB(_ pid: pid_t) -> Double? {
    var ri = rusage_info_v4()
    let r = withUnsafeMutablePointer(to: &ri) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return r == 0 ? Double(ri.ri_phys_footprint) / 1_048_576 : nil
  }
}
