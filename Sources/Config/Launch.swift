import Cocoa

let args = CommandLine.arguments

/// The value after a flag: `--theme reef` gives "reef".
func argValue(_ k: String) -> String? {
  guard let i = args.firstIndex(of: k), i + 1 < args.count else { return nil }
  return args[i + 1]
}

/// A test run (--bench, development builds only): no updates, login item, menu or saved settings.
#if TIDEWALL_DEV
let benchMode = args.contains("--bench")
#else
let benchMode = false
#endif

/// --behind (dev): every test window sits behind the real wallpaper and the app never comes forward, so the regression
/// suite runs while you work. The pages still render: bench turns WebKit's occlusion detection off.
let benchBehind = (benchMode && args.contains("--behind")) || TestIsolation.on

/// One level below the desktop's own: under whichever wallpaper is showing, Tidewall's or the system's.
let behindLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)

/// --snapshot pictures not yet written (dev); the run waits for them.
var shotsPending = 0

/// --stock: the baseline, with the native pixel ratio, and the theme's own pacing.
let stock = args.contains("--stock")

let themesRoot: URL = {
  if let p = argValue("--themes") { return URL(fileURLWithPath: p).standardized }
  return Bundle.main.resourceURL!.appendingPathComponent("themes").standardized
}()
