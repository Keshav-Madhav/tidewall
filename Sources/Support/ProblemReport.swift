import Cocoa

/// Tidewall ▸ About ▸ Report a problem: everything someone fixing it needs (versions, Mac model, displays and walls,
/// settings, the end of the log) and nothing that says who or where you are. The issue form opens with the summary; the
/// log goes only on the clipboard, for you to paste in (a URL would hand it to GitHub before you'd sent anything).
enum ProblemReport {
  private static let newIssue = "https://github.com/Keshav-Madhav/tidewall/issues/new"

  static func send() {
    // TIDEWALL_REPORT_DRYRUN=<file> (development and tests): the clipboard text goes to that file and the issue
    // address to the log, leaving your clipboard and browser alone
    if let file = ProcessInfo.processInfo.environment["TIDEWALL_REPORT_DRYRUN"] {
      try? clipboardText().write(toFile: file, atomically: true, encoding: .utf8)
      log("[report] \(issueURL().absoluteString)")
      return
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(clipboardText(), forType: .string)
    NSWorkspace.shared.open(issueURL())
  }

  static func clipboardText() -> String { summary() + "\n\n### The end of Tidewall's log\n```\n" + logTail(12_000) + "\n```\n" }

  static func issueURL() -> URL {
    var components = URLComponents(string: newIssue)!
    let logNote = "\n\n### The end of Tidewall's log\n<!-- Tidewall copied it to your clipboard: paste it here (⌘V) if you're happy to share it. Your name, folders and location are already taken out. -->\n"
    components.queryItems = [URLQueryItem(name: "body", value: summary() + logNote)]
    // a "+" would arrive as a space
    components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    return components.url ?? URL(string: newIssue)!
  }

  private static func summary() -> String {
    let os = ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: "Version ", with: "")
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    let displays = NSScreen.screens.map { screen in
      let size = "\(Int(screen.frame.width))×\(Int(screen.frame.height)) @\(Int(screen.backingScaleFactor))x"
      return "\(displayName(screen)) \(size): \(themeName(Cfg.theme(for: screen.displayID)))"
    }
    return scrub("""
    ### What happened?
    <!-- What did you see, and what were you doing just before? A screenshot or a short screen recording helps a lot. -->


    ### This Mac
    - Tidewall \(Cfg.version) (\(build)), macOS \(os)
    - \(sysctl("hw.model")), \(sysctl("machdep.cpu.brand_string"))
    \(displays.map { "- " + $0 }.joined(separator: "\n"))
    - \(settings.joined(separator: " · "))
    """)
  }

  private static var settings: [String] {
    let reacts = [("windows", Cfg.reactWindows), ("Stage Manager", Cfg.reactStage), ("widgets", Cfg.reactWidgets), ("pointer", Cfg.reactCursor)]
    let reactsTo = reacts.filter { $0.1 }.map { $0.0 }.joined(separator: ", ").nilIfEmpty ?? "nothing"
    return [
      "frame rate \(Cfg.fps == 0 ? "Auto" : "\(Int(Cfg.fps))")",
      "on battery \(["same", "calmer", "paused"][Cfg.battery])",
      "rest when idle \(Cfg.idleMinutes > 0 ? "\(Int(Cfg.idleMinutes)) min" : "never")",
      "desktop icons \(Cfg.deskIcons ? "on" : "off")",
      "reacts to \(reactsTo)",
      "updates \(Cfg.autoUpdate ? "automatic" : "manual")",
      "paused \(Cfg.d.bool(forKey: "paused") ? "yes" : "no")",
    ]
  }

  /// A display as the report names it: the model for a monitor, but a Sidecar iPad or AirPlay screen is named by its
  /// owner ("Jo's iPad"), so anything that isn't plainly a model is just "a named display".
  private static func displayName(_ screen: NSScreen) -> String {
    let name = screen.localizedName
    if name.hasPrefix("Built-in") { return name }
    let owned = name.contains("’") || name.contains("'")
      || name.range(of: "iPad|iPhone|TV|AirPlay|Sidecar", options: .regularExpression) != nil
    return owned ? "a named display" : name
  }

  private static func themeName(_ id: String) -> String {
    guard let theme = Cfg.themes.first(where: { $0.0 == id }) else { return id }
    return String(theme.1.split(separator: "·").first ?? "").trimmingCharacters(in: .whitespaces)
  }

  private static func sysctl(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
    return String(cString: buffer)
  }

  /// The last lines of the log that fit in `max` characters, leaving out the twice-a-second pacing lines.
  private static func logTail(_ max: Int) -> String {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Tidewall.log")
    guard let handle = try? FileHandle(forReadingFrom: url) else { return "(no log yet)" }
    let readBack: UInt64 = 150_000
    let end = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: end > readBack ? end - readBack : 0)
    var lines = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
    try? handle.close()
    // read from mid-line, the first is a fragment
    if end > readBack, !lines.isEmpty { lines.removeFirst() }
    var kept: [Substring] = []
    var used = 0
    for fullLine in lines.reversed() where !fullLine.hasPrefix("HOST polls") {
      let line = fullLine.prefix(300)
      if used + line.count + 1 > max { break }
      kept.append(line)
      used += line.count + 1
    }
    return scrub(kept.reversed().joined(separator: "\n"))
  }

  /// No home folder, account or full name (any part of it, any case), drive names, place, time zone or coordinates
  /// (the walls' addresses carry the place for the weather, and Wind Map's region is your country).
  private static func scrub(_ s: String) -> String {
    var t = s.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    t = replace(t, "/Users/[^/\\s:]+", "/Users/<you>")
    t = replace(t, "/Volumes/[^/\\n:]+", "/Volumes/<drive>")
    t = scrubNames(t)
    t = scrubPlace(t)
    t = replace(t, "([?&;])(site|lat|lon|latitude|longitude|tz|timezone|v|region)=[^&\\s:]*", "$1$2=…")
    return t
  }

  /// The account name however a path mangles it ("jo_smith" also as jo-smith or jo.smith: folders made from paths),
  /// then the full name and each part of it: 4 letters or more matched even inside other words ("josmith"), 3 only as
  /// a word of its own (so "Ann" leaves "annotation" alone).
  private static func scrubNames(_ s: String) -> String {
    var t = s
    let flexible = { (name: String) in
      name.map { "_-. ".contains($0) ? "[-_. ]?" : NSRegularExpression.escapedPattern(for: String($0)) }.joined()
    }
    for name in [NSUserName(), NSFullUserName()] where name.count >= 3 {
      t = replace(t, flexible(name), "<you>", .caseInsensitive)
    }
    let parts = Set(NSFullUserName().split(whereSeparator: { !$0.isLetter }).map(String.init)).sorted { $0.count > $1.count }
    for part in parts where part.count >= 3 {
      let escaped = NSRegularExpression.escapedPattern(for: part)
      let pattern = part.count >= 4 ? escaped : "(?<![A-Za-z])" + escaped + "(?![A-Za-z])"
      t = replace(t, pattern, "<you>", .caseInsensitive)
    }
    return t
  }

  private static func scrubPlace(_ s: String) -> String {
    guard let site = Cfg.site else { return s }
    var t = s
    let forms = [
      site.tz,
      site.name,
      site.name.replacingOccurrences(of: " ", with: "_"),
      site.tz.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "",
    ]
    for form in forms where form.count >= 3 {
      t = replace(t, NSRegularExpression.escapedPattern(for: form), "<place>", .caseInsensitive)
    }
    return t
  }

  private static func replace(_ t: String, _ pattern: String, _ with: String, _ opts: NSRegularExpression.Options = []) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return t }
    return re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: with)
  }
}

extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
