import Cocoa

/// A pretend pointer for tests: tools/mover broadcasts a cursor riding a window's title bar, button held.
/// Development builds only, and only with TIDEWALL_SIM=1; the window tracker reads it in place of the real pointer.
enum SimInput {
  #if TIDEWALL_DEV
  static let on = ProcessInfo.processInfo.environment["TIDEWALL_SIM"] == "1"
  #else
  static let on = false
  #endif
  static var point: NSPoint?
  static var pressed = false

  static func start() {
    guard on else { return }
    DistributedNotificationCenter.default().addObserver(forName: .init("tidewall.sim"), object: nil, queue: .main) { n in
      let u = n.userInfo ?? [:]
      point = NSPoint(x: u["x"] as? Double ?? 0, y: u["y"] as? Double ?? 0)
      pressed = (u["down"] as? Bool) ?? false
    }
  }
}
