// Test helper that drags like a person: waypoints, eased moves of varying speed, holds of 0.3–1.2 s,
// the odd quick flick and slow creep. Then it closes one window and minimises another.
import Cocoa
let app = NSApplication.shared; app.setActivationPolicy(.regular)
func make(_ x: CGFloat, _ y: CGFloat, _ title: String) -> NSWindow {
  let w = NSWindow(contentRect: NSRect(x: x, y: y, width: 620, height: 400), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
  w.title = title; w.isReleasedWhenClosed = false; w.orderFrontRegardless(); return w
}
let a = make(260, 300, "drag me"), b = make(820, 120, "minimise me")
a.setContentSize(NSSize(width: 1070, height: 820))      // Slack-sized, like real use
func sim(_ down: Bool) {                                   // a fake cursor on the title bar, button held while moving
  let f = a.frame; DistributedNotificationCenter.default().postNotificationName(.init("driftland.sim"), object: nil,
    userInfo: ["x": Double(f.midX - 200), "y": Double(f.maxY - 12), "down": down], deliverImmediately: true)
}
var rnd = SystemRandomNumberGenerator()
func r(_ lo: Double, _ hi: Double) -> Double { Double.random(in: lo...hi, using: &rnd) }
let f = NSScreen.screens[0].visibleFrame
var from = a.frame.origin, to = from, t0 = Date(), dur = 0.0, hold = 0.0, moves = 0
func next() {
  from = a.frame.origin
  to = NSPoint(x: f.minX + r(-200, Double(f.width) - 870), y: f.minY + r(-200, Double(f.height) - 620))
  let kind = r(0, 1); dur = kind < 0.2 ? r(0.12, 0.25) : kind < 0.8 ? r(0.5, 1.2) : r(1.6, 2.6)   // flick / normal / creep
  hold = r(0, 1) < 0.6 ? r(0.3, 1.2) : 0; t0 = Date(); moves += 1
}
next()
var phase = 0, phaseT = Date()
Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { _ in
  if phase == 0 {
    let e = Date().timeIntervalSince(t0)
    if e < dur { let u = e / dur, s = u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
      a.setFrameOrigin(NSPoint(x: from.x + (to.x - from.x) * s + CGFloat(r(-1.5, 1.5)), y: from.y + (to.y - from.y) * s + CGFloat(r(-1.5, 1.5)))); sim(true) }
    else if e < dur + hold { sim(r(0, 1) < 0.5) }        // holds: sometimes still gripping, sometimes let go
    else if e > dur + hold { if moves >= 9 { phase = 1; phaseT = Date(); print("closing 'drag me'"); sim(false); a.close() } else { next() } }
  } else if phase == 1, Date().timeIntervalSince(phaseT) > 2.5 { phase = 2; phaseT = Date(); print("minimising"); b.miniaturize(nil) }
  else if phase == 2, Date().timeIntervalSince(phaseT) > 3 { exit(0) }
}
app.run()
