import Cocoa

/// The settings, kept in UserDefaults (a suite of its own for an isolated test copy), and what follows from them.
enum Cfg {
  static let d = TestIsolation.on ? UserDefaults(suiteName: "tidewall.isolated-test")! : UserDefaults.standard
  static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"

  /// Tidewall was called Driftland: bring its choices along, once.
  static func migrate() {
    guard !d.bool(forKey: "migrated.driftland"), let old = UserDefaults(suiteName: "driftland") else { return }
    let settings = ["theme", "margin", "fps", "seed", "restWhenIdle"]
    let carried = { (k: String) in settings.contains(k) || k.hasPrefix("theme.display.") || k.hasPrefix("variant.") }
    for (k, v) in old.dictionaryRepresentation() where carried(k) {
      if d.object(forKey: k) == nil { d.set(v, forKey: k) }
    }
    d.set(true, forKey: "migrated.driftland")
    // Driftland opened at login: Tidewall does now
    if Bundle.main.bundleIdentifier != nil && !benchMode && FileManager.default.fileExists(atPath: LoginItem.oldPlists[0].path) {
      LoginItem.set(true)
    }
  }

  /// The wall a new install opens on.
  static let defaultTheme = "inkmap"

  /// Marauders was the default until 1.2.8: an install that never picked a wall keeps the one it has been showing.
  static func keepFormerDefaultTheme() {
    guard d.string(forKey: "theme") == nil, d.bool(forKey: "welcomed") else { return }
    d.set("estate", forKey: "theme")
  }

  /// Driftland's frame rate came across in the move and, since 1.2.6, caps even transitions: back to Auto, once, unless
  /// it has been changed since.
  static func resetInheritedFrameRate() {
    defer { d.set(true, forKey: "fps.reset.1.2.7") }
    guard !d.bool(forKey: "fps.reset.1.2.7"), d.bool(forKey: "migrated.driftland"),
          let inherited = UserDefaults(suiteName: "driftland")?.object(forKey: "fps") as? Double,
          inherited > 0, fps == inherited else { return }
    fps = 0
  }

  // MARK: themes and displays

  static let themes: [(String, String)] = [
    ("inkmap", "Ink Map · very low"),
    ("estate", "Marauders · very low"),
    ("gallery", "Gallery · none"),
    ("wind", "Wind Map · medium"),
    ("lava", "Lava Lamp · low"),
    ("tunnel", "Wind Tunnel · high"),
    ("reef", "Koi Reef · medium"),
    ("snow", "Snowfall · low"),
    ("celestial", "Celestial Atlas · none"),
    ("courtyard", "Courtyard · low"),
    ("garden", "Garden Plan · very low"),
    ("railway", "Model Railway · very low"),
    ("meadow", "Meadow · high"),
    ("beach", "Beach · medium"),
  ]

  /// Themes that can draw one world across every display showing them; the rest draw each display on its own.
  static let spanThemes: Set<String> = ["celestial", "snow", "wind", "railway", "reef", "inkmap", "garden", "gallery", "beach",
                                        "meadow", "estate"]

  /// --theme, for tests: shown everywhere and never saved over your choice.
  static var themeOverride: String?

  static var theme: String {
    get { themeOverride ?? d.string(forKey: "theme") ?? defaultTheme }
    set {
      themeOverride = nil
      d.set(newValue, forKey: "theme")
    }
  }

  static func theme(for id: CGDirectDisplayID) -> String { themeOverride ?? d.string(forKey: "theme.display.\(id)") ?? theme }

  static func setTheme(_ t: String?, for id: CGDirectDisplayID) { d.set(t, forKey: "theme.display.\(id)") }

  static func clearDisplayThemes() {
    for k in d.dictionaryRepresentation().keys where k.hasPrefix("theme.display.") {
      d.removeObject(forKey: k)
    }
  }

  /// A theme's name as the menu shows it ("Model Railway"), without the cost tier.
  static func label(_ id: String) -> String {
    let title = themes.first { $0.0 == id }?.1 ?? id
    return title.components(separatedBy: " · ").first ?? id
  }

  /// The sharpest a theme is drawn, in device pixels per point: 8, the display's own, for all. 1.1.0's 1.5× retina caps
  /// saved little GPU and looked soft; --lowres-test brings them back, for comparisons only.
  static func renderCap(_ t: String) -> Double {
    guard CommandLine.arguments.contains("--lowres-test") else { return 8 }
    let oldCaps = ["lava": 1.25, "reef": 1.5, "beach": 1.5, "meadow": 1.5, "tunnel": 1.5, "wind": 1.5, "snow": 1.5]
    return oldCaps[t] ?? 8
  }

  /// Displays showing the same spanning theme share one world (off: each draws its own). --solo (dev) turns it off.
  static var spanWorlds: Bool {
    get { CommandLine.arguments.contains("--solo") ? false : d.object(forKey: "spanWorlds") as? Bool ?? true }
    set { d.set(newValue, forKey: "spanWorlds") }
  }

  static func world(of id: CGDirectDisplayID) -> [NSScreen] {
    let t = theme(for: id)
    guard spanWorlds, spanThemes.contains(t) else { return NSScreen.screens.filter { $0.displayID == id } }
    return NSScreen.screens.filter { theme(for: $0.displayID) == t }
  }

  static var variantOverride: String?

  /// Each theme's own sub-choice (Wind Map's region, Lava Lamp's colours, …), declared in themes/variants.json.
  static func variant(_ t: String) -> String? {
    if t == theme, let v = variantOverride { return v }
    if let saved = d.string(forKey: "variant.\(t)") { return saved }
    if t == "wind", let region = homeRegion { return region }
    // Wind Tunnel with no model chosen blows over your desktop icons, when you have some
    if t == "tunnel" && hasDesktopIcons { return "none" }
    return nil
  }

  static func setVariant(_ t: String, _ v: String) {
    variantOverride = nil
    d.set(v, forKey: "variant.\(t)")
  }

  /// Before the icons have been read this launch, the last launch's answer.
  private static var hasDesktopIcons: Bool {
    guard let icons = DeskIcons.shared, icons.known else { return d.bool(forKey: "iconsPresent") }
    return !icons.icons.isEmpty
  }

  // MARK: where you are

  /// Where the sky is drawn from: where Location Services says you are (Locator: rounded, kept on this Mac), else the
  /// city of your time zone. The country (for Wind Map's region) always comes from the time zone.
  static var site: (name: String, lat: Double, lon: Double, tz: String, cc: String)? {
    guard let h = Locator.here else { return zoneSite }
    let z = zoneSite
    return (h.name ?? z?.name ?? "Here", h.lat, h.lon, z?.tz ?? TimeZone.current.identifier, z?.cc ?? "")
  }

  /// The city of your time zone, from the system's time-zone table (no location permission).
  private static let zoneSite: (name: String, lat: Double, lon: Double, tz: String, cc: String)? = {
    let tz = TimeZone.current.identifier
    guard let table = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8) else { return nil }
    for line in table.split(separator: "\n") where !line.hasPrefix("#") {
      let fields = line.split(separator: "\t")
      guard fields.count >= 3, fields[2] == tz else { continue }
      guard let at = coordinates(String(fields[1])) else { return nil }
      let city = tz.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? tz
      return (city, at.lat, at.lon, tz, String(fields[0]))
    }
    return nil
  }()

  /// zone.tab's "+2232+08822" or "+404251-0740023": ±DDMM[SS] then ±DDDMM[SS].
  private static func coordinates(_ iso: String) -> (lat: Double, lon: Double)? {
    guard let split = iso.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
    return (degrees(iso[iso.startIndex..<split], wholeDigits: 2), degrees(iso[split...], wholeDigits: 3))
  }

  private static func degrees(_ s: Substring, wholeDigits: Int) -> Double {
    let sign: Double = s.first == "-" ? -1 : 1
    let digits = s.dropFirst()
    let whole = Double(digits.prefix(wholeDigits)) ?? 0
    let minutes = Double(digits.dropFirst(wholeDigits).prefix(2)) ?? 0
    let seconds = Double(digits.dropFirst(wholeDigits + 2).prefix(2)) ?? 0
    return sign * (whole + minutes / 60 + seconds / 3600)
  }

  static var siteQuery: String {
    guard let s = site else { return "" }
    let e = { (v: String) in v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
    return "&site=\(e(s.name))&lat=\(String(format: "%.3f", s.lat))&lon=\(String(format: "%.3f", s.lon))&tz=\(e(s.tz))"
  }

  /// Wind Map's default region: the user's own country, if the map has it.
  static let homeRegion: String? = {
    guard let cc = zoneSite?.cc, !cc.isEmpty, let country = Locale(identifier: "en_US").localizedString(forRegionCode: cc),
          let data = try? Data(contentsOf: themesRoot.appendingPathComponent("variants.json")),
          let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let wind = manifest["wind"] as? [String: Any] else { return nil }
    let options = (wind["groups"] as? [[String: Any]] ?? []).flatMap { $0["options"] as? [[String: Any]] ?? [] }
    func norm(_ s: String) -> String {
      s.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter }
    }
    let name = { (option: [String: Any]) in norm(option["name"] as? String ?? "") }
    let wanted = norm(country)
    let match = options.first { name($0) == wanted } ?? options.first { name($0).hasPrefix(wanted) || wanted.hasPrefix(name($0)) }
    return match?["id"] as? String
  }()

  // MARK: settings

  /// How far (pt) the land or cloud bank reaches past each window edge.
  static var margin: Double { get { clamped("margin", to: 0...400) ?? 140 } set { d.set(newValue, forKey: "margin") } }
  static var fps: Double { get { clamped("fps", to: 0...120) ?? 0 } set { d.set(newValue, forKey: "fps") } }
  /// Settings ▸ Optimize for: 0 Performance, 1 Balanced (the default), 2 Quality. Every wall a little leaner or richer
  /// in every part (resolution, frame rates, particles, simulation detail, effects): see themes/host/early.js.
  static var tier: Int {
    get { if let t = argValue("--tier").flatMap(Int.init) { return max(0, min(2, t)) }   // (benches and tests)
          return d.object(forKey: "tier") == nil ? 1 : max(0, min(2, d.integer(forKey: "tier"))) }
    set { d.set(newValue, forKey: "tier") } }
  /// The share of the display's pixels Performance draws (the page and the host's messages both use it).
  static var tierRes: Double { tier == 0 ? 0.75 : 1 }

  /// Seeds the generated names (your walker, the strangers); stable across launches.
  static var seed: Int {
    if let v = d.object(forKey: "seed") as? Int { return v }
    let v = Int.random(in: 1..<Int(Int32.max))
    d.set(v, forKey: "seed")
    return v
  }

  /// Make room for desktop icons (reading where they are needs macOS's one-time "control Finder" permission).
  static var deskIcons: Bool { get { d.bool(forKey: "deskIcons") } set { d.set(newValue, forKey: "deskIcons") } }

  static var autoUpdate: Bool { get { flag("autoUpdate") } set { d.set(newValue, forKey: "autoUpdate") } }

  static var restWhenIdle: Bool { get { flag("restWhenIdle") } set { d.set(newValue, forKey: "restWhenIdle") } }

  /// Minutes without input before the wallpaper rests (0: never). Before this setting it was on or off at 3.
  static var idleMinutes: Double {
    get { clamped("idleMinutes", to: 0...120) ?? (restWhenIdle ? 3 : 0) }
    set {
      d.set(newValue, forKey: "idleMinutes")
      restWhenIdle = newValue > 0
      if newValue > 0 { d.set(newValue, forKey: "idleLast") }
    }
  }

  /// The last non-zero idle time, for switching rest back on.
  static var idleLast: Double { (d.object(forKey: "idleLast") as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 3 }

  /// What the scene reshapes itself around (your windows, Stage Manager's thumbnails, desktop widgets) and whether it
  /// reacts to the pointer. Off: the wallpaper carries on as if that weren't there.
  static var reactWindows: Bool { get { flag("reactWindows") } set { d.set(newValue, forKey: "reactWindows") } }
  static var reactStage: Bool { get { flag("reactStage") } set { d.set(newValue, forKey: "reactStage") } }
  static var reactWidgets: Bool { get { flag("reactWidgets") } set { d.set(newValue, forKey: "reactWidgets") } }
  static var reactCursor: Bool { get { flag("reactCursor") } set { d.set(newValue, forKey: "reactCursor") } }

  /// On battery: 0 the same, 1 calmer (half the frame rate), 2 paused.
  static var battery: Int {
    get { (d.object(forKey: "battery") as? Int).map { min(2, max(0, $0)) } ?? 0 }
    set { d.set(newValue, forKey: "battery") }
  }


  private static func flag(_ k: String, _ def: Bool = true) -> Bool { d.object(forKey: k) as? Bool ?? def }

  private static func clamped(_ key: String, to range: ClosedRange<Double>) -> Double? {
    guard let v = d.object(forKey: key) as? Double, v.isFinite else { return nil }
    return min(range.upperBound, max(range.lowerBound, v))
  }

  /// The newest version whose What's New you've seen (nil: none yet; a fresh install starts at its own version).
  static var notesSeen: String? { get { d.string(forKey: "notesSeen") } set { d.set(newValue, forKey: "notesSeen") } }

  static var hasNewNotes: Bool { notesSeen.map { Updater.newer(version, than: $0) } ?? true }

  /// CHANGELOG.md, bundled beside the themes (or the repo's, in a development build).
  static var changelog: String {
    let candidates = [Bundle.main.resourceURL?.appendingPathComponent("CHANGELOG.md"),
                      themesRoot.deletingLastPathComponent().appendingPathComponent("CHANGELOG.md")]
    for url in candidates.compactMap({ $0 }) {
      if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
    }
    return ""
  }
}

/// Development builds only: a copy whose Info.plist says TidewallIsolatedTest (the update tests make such copies, and
/// their releases) keeps entirely to itself: its own settings and log, never replaces or signals the Tidewall you're
/// running, never touches the login item, and draws behind your wallpaper. Release builds ignore the key.
enum TestIsolation {
#if TIDEWALL_DEV
  static let on = Bundle.main.object(forInfoDictionaryKey: "TidewallIsolatedTest") as? Bool ?? false
#else
  static let on = false
#endif
}
