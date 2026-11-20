import Cocoa

/// Test harness (--fakescreens): pretend displays, id → frame in CG points, each drawn by a page in this one app.
var fakeWorld: [CGDirectDisplayID: CGRect] = [:]
/// Each pretend display's pixels per point (an ordinary external monitor is 1×, so its page draws at 1×, as on a real one).
var fakeScale: [CGDirectDisplayID: CGFloat] = [:]

/// The displays this display's page draws one world across: those showing the same spanning theme, or just this one.
func worldFrames(for id: CGDirectDisplayID) -> [CGRect] {
  guard !fakeWorld.isEmpty else { return Cfg.world(of: id).map { $0.cgFrame } }
  let theme = Cfg.theme(for: id)
  guard Cfg.spanWorlds && Cfg.spanThemes.contains(theme) else { return [fakeWorld[id] ?? .zero] }
  return fakeWorld.keys.sorted().filter { Cfg.theme(for: $0) == theme }.compactMap { fakeWorld[$0] }
}

func allFrames() -> [CGRect] {
  if fakeWorld.isEmpty { return NSScreen.screens.map { $0.cgFrame } }
  return fakeWorld.keys.sorted().compactMap { fakeWorld[$0] }
}

/// Display names as people see them, with the size (or the position) added when two share a name.
func displayNames() -> [CGDirectDisplayID: String] {
  var names: [CGDirectDisplayID: String] = [:]
  for s in NSScreen.screens {
    let sameName = NSScreen.screens.filter { $0.localizedName == s.localizedName }
    if sameName.count < 2 {
      names[s.displayID] = s.localizedName
      continue
    }
    let size = s.frame.size
    let sameSize = sameName.filter { $0.frame.size == size }
    if sameSize.count < 2 {
      names[s.displayID] = "\(s.localizedName) (\(Int(size.width))×\(Int(size.height)))"
    } else {
      let position = (sameSize.sorted { $0.frame.minX < $1.frame.minX }.firstIndex(of: s) ?? 0) + 1
      names[s.displayID] = "\(s.localizedName) (\(position))"
    }
  }
  return names
}

extension NSScreen {
  /// 0 for a moment while displays reconfigure.
  var displayID: CGDirectDisplayID { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0 }

  /// The frame in CG global coordinates: points, origin at the top left of the main display.
  var cgFrame: CGRect {
    let h = NSScreen.screens.first?.frame.height ?? frame.maxY
    return CGRect(x: frame.minX, y: h - frame.maxY, width: frame.width, height: frame.height)
  }
}
