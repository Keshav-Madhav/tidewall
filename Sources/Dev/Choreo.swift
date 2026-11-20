#if TIDEWALL_DEV
import Cocoa

/// A scripted desk for filming (--choreo file.json), in points and scene seconds: windows with keyframes
/// [[t, x, y, w, h], …] eased between, optional "from"/"until" times, Stage Manager cards ("sm": true), and a cursor
/// path [[t, x, y], …].
struct Choreo {
  struct Window {
    let name: String
    let keys: [[Double]]
    let from: Double
    let until: Double
    let stageCard: Bool
  }

  let windows: [Window]
  let cursorKeys: [[Double]]

  init?(path: String) {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    windows = (o["windows"] as? [[String: Any]] ?? []).map { w in
      Window(name: w["name"] as? String ?? "", keys: w["keys"] as? [[Double]] ?? [], from: w["from"] as? Double ?? -1e9,
             until: w["until"] as? Double ?? 1e9, stageCard: w["sm"] as? Bool ?? false)
    }
    cursorKeys = o["cursor"] as? [[Double]] ?? []
  }

  /// The values at time t, smootherstep-eased between the keyframes either side.
  static func ease(_ keys: [[Double]], _ t: Double) -> [Double] {
    guard let first = keys.first else { return [] }
    if t <= first[0] { return Array(first.dropFirst()) }
    for (a, b) in zip(keys, keys.dropFirst()) where t <= b[0] {
      let u = (t - a[0]) / max(1e-6, b[0] - a[0]), e = u * u * u * (u * (u * 6 - 15) + 10)
      return zip(a.dropFirst(), b.dropFirst()).map { $0 + ($1 - $0) * e }
    }
    return Array(keys.last!.dropFirst())
  }

  /// The windows on show at time t: frames, apps, and which are Stage Manager cards.
  func at(_ t: Double) -> ([CGRect], [String], [Bool]) {
    var rects: [CGRect] = [], names: [String] = [], cards: [Bool] = []
    for w in windows where t >= w.from && t < w.until {
      let v = Choreo.ease(w.keys, t)
      guard v.count == 4 else { continue }
      rects.append(CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))
      names.append(w.name)
      cards.append(w.stageCard)
    }
    return (rects, names, cards)
  }

  func cursor(_ t: Double) -> CGPoint? {
    let v = Choreo.ease(cursorKeys, t)
    return v.count == 2 ? CGPoint(x: v[0], y: v[1]) : nil
  }

  /// Puts the scripted cursor (or, with none, a point far off screen) where the tracker reads simulated input, so the
  /// real mouse can't send competing positions mid-take.
  func pinCursor(_ t: Double) {
    let h = NSScreen.screens.first?.frame.height ?? 0, p = cursor(t) ?? CGPoint(x: -4000, y: -4000)
    SimInput.point = NSPoint(x: p.x, y: h - p.y)
  }
}
#endif
