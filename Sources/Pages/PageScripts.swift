import Cocoa
import WebKit

/// The scripts injected into every wallpaper page live in themes/host/ as plain JavaScript. early.js and timescale.js
/// are function expressions the host calls with its settings; late.js runs as is.
enum HostScript {
  static let early = load("early")
  static let late = load("late")
  static let timescale = load("timescale")

  private static func load(_ name: String) -> String {
    let url = themesRoot.appendingPathComponent("host/\(name).js")
    guard let source = try? String(contentsOf: url, encoding: .utf8) else {
      log("JSERR host script missing: \(url.path)")
      return "(() => {})"
    }
    return source
  }
}

/// Runs before any page script.
func earlyScript(fps: Double, opaque: Bool, cap: Double = 8, maxHz: Int = 60, tier: Int = 1, res: Double = 1) -> String {
  HostScript.early + "({ fps: \(fps), opaque: \(opaque), cap: \(cap), maxHz: \(maxHz), profile: \(args.contains("--profile")), tier: \(tier), res: \(res) });"
}

/// Runs after the page's own scripts.
let lateScript = HostScript.late

func timescaleScript(_ k: Double) -> String { HostScript.timescale + "(\(k));" }

/// WebKit caps page rendering near 60 fps by default, so on a 120 Hz display the wallpaper trails a dragged window.
/// This turns that internal feature off (private API, guarded: it does nothing if the feature ever disappears).
func unlockHighRefresh(_ prefs: WKPreferences) {
  let cls: AnyObject = WKPreferences.self
  let featuresSel = NSSelectorFromString("_features")
  guard cls.responds(to: featuresSel), let features = cls.perform(featuresSel)?.takeUnretainedValue() as? [NSObject] else {
    log("high-refresh: no _features")
    return
  }
  let setSel = NSSelectorFromString("_setEnabled:forFeature:")
  guard prefs.responds(to: setSel), let imp = class_getMethodImplementation(type(of: prefs), setSel) else {
    log("high-refresh: no setter")
    return
  }
  typealias SetFeature = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
  let setEnabled = unsafeBitCast(imp, to: SetFeature.self)
  for f in features where (f.value(forKey: "key") as? String) == "PreferPageRenderingUpdatesNear60FPSEnabled" {
    setEnabled(prefs, setSel, false, f)
    log("high-refresh: unlocked")
  }
}
