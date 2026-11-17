// Minimise a window and log what CGWindowList reports for its app, 120×/s.
import Cocoa
let app = NSApplication.shared; app.setActivationPolicy(.regular)
let w = NSWindow(contentRect: NSRect(x: 400, y: 300, width: 900, height: 600), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
w.title = "minprobe"; w.orderFrontRegardless()
let me = ProcessInfo.processInfo.processIdentifier, t0 = Date()
var last = ""
Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { _ in
  let t = Date().timeIntervalSince(t0)
  if t > 0.6 && t < 0.62 { print("--- miniaturize at \(String(format: "%.3f", t))"); w.miniaturize(nil) }
  let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
  let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == me || ($0[kCGWindowOwnerName as String] as? String) == "Dock" && ($0[kCGWindowLayer as String] as? Int ?? 0) != 20 }
  let s = mine.map { d -> String in let b = d[kCGWindowBounds as String] as! [String: CGFloat]
    return "\(d[kCGWindowOwnerName as String]!) L\(d[kCGWindowLayer as String]!) a\(String(format: "%.2f", d[kCGWindowAlpha as String] as! Double)) \(Int(b["X"]!)),\(Int(b["Y"]!)) \(Int(b["Width"]!))x\(Int(b["Height"]!))" }.joined(separator: " | ")
  if s != last { print(String(format: "%.3f ", t) + s); last = s }
  if t > 2.4 { exit(0) }
}
app.run()
