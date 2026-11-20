import Cocoa
import IOKit

/// What Tidewall costs: CPU, GPU and memory of the app and every helper process macOS bills to it (WebKit's, mostly).
final class Usage {
  struct Sample {
    var cpu = 0.0, gpu = 0.0, memMB = 0.0, procs = 0
    var cpuBy: [pid_t: Double] = [:], memBy: [pid_t: Double] = [:]
  }

  /// The counters at one moment: CPU time per process (Mach time units), memory per process (MB), GPU time (ns).
  private struct Counters {
    var t: Double
    var pids: [pid_t]
    var cpu: [pid_t: UInt64]
    var mem: [pid_t: Double]
    var gpu: UInt64
  }

  private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
  private static let responsible: ResponsibleFn? = {
    guard let h = dlopen(nil, RTLD_NOW), let s = dlsym(h, "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(s, to: ResponsibleFn.self)
  }()

  private let me = ProcessInfo.processInfo.processIdentifier
  private let nsPerTick: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom)
  }()

  /// The counters as they were every 15 s for the last minute or so. What the menu and the window show is the average
  /// since the oldest: what the wallpaper costs you over time. (Measured only from the moment you look, it was the cost
  /// of looking: the menu drawing itself, the pointer up in the menu bar.)
  private var marks: [Counters] = []
  private var last: Counters?

  var window: Double { marks.first.map { ProcessInfo.processInfo.systemUptime - $0.t } ?? 0 }

  func mark() {
    let now = counters()
    marks.append(now)
    marks.removeAll { now.t - $0.t > 70 }
  }

  /// The average since the oldest mark; just started (no mark 10 s old yet), since the last call.
  func sample() -> Sample {
    let now = counters()
    var s = Sample()
    s.procs = now.pids.count
    for (p, mb) in now.mem {
      s.memMB += mb
      s.memBy[p] = mb
    }
    let base = marks.first.flatMap { now.t - $0.t >= 10 ? $0 : nil } ?? last
    if let base, now.t - base.t > 0 {
      let dt = now.t - base.t
      var allCPU: UInt64 = 0
      for (p, c) in now.cpu {
        let before = base.cpu[p] ?? 0   // a process that started since: all of its time is in the window
        guard c >= before else { continue }
        allCPU += c - before
        s.cpuBy[p] = cpuPercent(c - before, over: dt)
      }
      s.cpu = cpuPercent(allCPU, over: dt)
      s.gpu = Double(now.gpu >= base.gpu ? now.gpu - base.gpu : 0) / 1e9 / dt * 100
    }
    last = now
    return s
  }

  private func cpuPercent(_ ticks: UInt64, over dt: Double) -> Double {
    Double(ticks) * nsPerTick / 1e9 / dt * 100
  }

  private func counters() -> Counters {
    let t = ProcessInfo.processInfo.systemUptime, pids = family()
    var cpu: [pid_t: UInt64] = [:], mem: [pid_t: Double] = [:]
    for p in pids {
      guard let r = rusage(p) else { continue }
      cpu[p] = r.ri_user_time + r.ri_system_time
      mem[p] = Double(r.ri_phys_footprint) / 1_048_576
    }
    return Counters(t: t, pids: pids, cpu: cpu, mem: mem, gpu: gpuNs(Set(pids)))
  }

  private func family() -> [pid_t] {
    var pids = [me]
    guard let resp = Self.responsible else { return pids }
    let n = proc_listallpids(nil, 0)
    var buf = [pid_t](repeating: 0, count: Int(n) + 64)
    let count = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.size))
    guard count > 0 else { return pids }
    for p in buf.prefix(Int(count)) where p > 0 && p != me && resp(p) == me { pids.append(p) }
    return pids
  }

  private func rusage(_ pid: pid_t) -> rusage_info_v4? {
    var ri = rusage_info_v4()
    let r = withUnsafeMutablePointer(to: &ri) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return r == 0 ? ri : nil
  }

  /// GPU busy time (ns) the driver has billed to these pids (WebKit's GPU work is billed to the app). The per-process
  /// counters live on the GPU driver's user clients, children of the accelerator: walk just those (walking the whole
  /// I/O registry to find them cost ~25 ms of main thread per reading).
  private func gpuNs(_ pids: Set<pid_t>) -> UInt64 {
    var it: io_iterator_t = 0
    let found = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it)
    guard found == KERN_SUCCESS else { return 0 }
    defer { IOObjectRelease(it) }
    var total: UInt64 = 0
    while case let acc = IOIteratorNext(it), acc != 0 {
      defer { IOObjectRelease(acc) }
      var children: io_iterator_t = 0
      guard IORegistryEntryGetChildIterator(acc, kIOServicePlane, &children) == KERN_SUCCESS else { continue }
      defer { IOObjectRelease(children) }
      while case let client = IOIteratorNext(children), client != 0 {
        defer { IOObjectRelease(client) }
        guard let pid = creatorPid(client), pids.contains(pid),
              let usage = property(client, "AppUsage") as? [[String: Any]] else { continue }
        for u in usage { total += (u["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0 }
      }
    }
    return total
  }

  private func creatorPid(_ client: io_registry_entry_t) -> pid_t? {
    guard let creator = property(client, "IOUserClientCreator") as? String,
          let pidStr = creator.split(separator: ",").first?.split(separator: " ").last else { return nil }
    return pid_t(pidStr)
  }

  private func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
  }
}
