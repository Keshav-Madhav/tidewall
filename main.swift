// Tidewall — a live wallpaper for macOS that flows around your windows (GPL-3.0; began as a fork of github.com/BLEZZ0102/Deskland)
// as a live wallpaper that reshapes around your *windows* (incl. Stage Manager strip + desktop widgets),
// not desktop icons. Unofficial; not affiliated with or endorsed by the Deskland project.
//
// Perf design (each lever is measurable via --bench):
//   1. Window tracking needs NO permission: CGWindowListCopyWindowInfo gives bounds + owner.
//      Adaptive polling: ~2 Hz idle, display-rate while a mouse button is held / just after a change.
//   2. During drags the page snaps the field (refresh) instead of restarting the 1.8 s morph.
//   3. Stencil mask: pixels under opaque windows are never shaded.
//   4. Always native resolution (canvas = display pixels). No quality is traded for speed.
//   5. Per-screen pause when a screen is (almost) fully covered; all screens pause on sleep / lock.
import Cocoa
import CryptoKit
import ServiceManagement
import WebKit
import IOKit
import IOKit.ps
import Darwin

// MARK: - Config

enum Cfg {
  static let d = UserDefaults.standard
  static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
  /// Tidewall was called Driftland: bring its choices along, once
  static func migrate() {
    guard !d.bool(forKey: "migrated.driftland"), let old = UserDefaults(suiteName: "driftland") else { return }
    for (k, v) in old.dictionaryRepresentation() where ["theme", "margin", "fps", "seed", "restWhenIdle", "mask"].contains(k) || k.hasPrefix("theme.display.") || k.hasPrefix("variant.") {
      if d.object(forKey: k) == nil { d.set(v, forKey: k) } }
    d.set(true, forKey: "migrated.driftland")
    if Bundle.main.bundleIdentifier != nil && !benchMode && FileManager.default.fileExists(atPath: LoginItem.oldPlist.path) { LoginItem.set(true) }   // Driftland opened at login: Tidewall does now
  }
  static var themeOverride: String?       // --theme for tests: never saved over your choice
  static var theme: String { get { themeOverride ?? d.string(forKey: "theme") ?? "estate" } set { themeOverride = nil; d.set(newValue, forKey: "theme") } }
  /// a display can have its own theme (Displays ▸ …); otherwise it shows the main one
  static func theme(for id: CGDirectDisplayID) -> String { themeOverride ?? d.string(forKey: "theme.display.\(id)") ?? theme }
  static func setTheme(_ t: String?, for id: CGDirectDisplayID) { d.set(t, forKey: "theme.display.\(id)") }
  /// themes that can draw one world across every display showing them (the rest draw each display on its own)
  /// the sharpest a theme is drawn (device pixels per point): the soft, full-screen scenes are redrawn every frame
  /// and look the same a little under retina (the window server scales them up smoothly), at a fraction of the GPU
  /// work and memory; the crisp ones (ink, lettering, sprites) stay at full sharpness. --fullres (dev) turns it off
  static func renderCap(_ t: String) -> Double {
    if CommandLine.arguments.contains("--fullres") { return 8 }
    return ["lava": 1.25, "reef": 1.5, "beach": 1.5, "meadow": 1.5, "tunnel": 1.5, "wind": 1.5, "snow": 1.5][t] ?? 8
  }
  static let spanThemes: Set<String> = ["celestial", "snow", "wind", "railway", "reef", "inkmap", "garden", "gallery", "beach", "meadow", "estate"]
  /// displays showing the same spanning theme share one world (off: each display draws its own)
  static var spanWorlds: Bool { get { CommandLine.arguments.contains("--solo") ? false : d.object(forKey: "spanWorlds") as? Bool ?? true } set { d.set(newValue, forKey: "spanWorlds") } }   // --solo (dev): each display alone
  /// the displays (frames, CG points) that one world is drawn across: every display showing this spanning theme
  static func world(of id: CGDirectDisplayID) -> [NSScreen] {
    let t = theme(for: id)
    guard spanWorlds, spanThemes.contains(t) else { return NSScreen.screens.filter { $0.displayID == id } }
    return NSScreen.screens.filter { theme(for: $0.displayID) == t }
  }
  /// a theme's name as the menu shows it ("Model Railway"), without the cost tier
  static func label(_ id: String) -> String { (themes.first { $0.0 == id }?.1 ?? id).components(separatedBy: " · ").first ?? id }
  static func clearDisplayThemes() { for k in d.dictionaryRepresentation().keys where k.hasPrefix("theme.display.") { d.removeObject(forKey: k) } }
  static let themes: [(String, String)] = [("estate", "Marauders · very low"), ("gallery", "Gallery · none"), ("wind", "Wind Map · medium"), ("lava", "Lava Lamp · low"),
    ("tunnel", "Wind Tunnel · high"), ("reef", "Koi Reef · medium"), ("snow", "Snowfall · low"), ("celestial", "Celestial Atlas · none"),
    ("inkmap", "Ink Map · very low"), ("garden", "Garden Plan · very low"), ("railway", "Model Railway · very low"), ("meadow", "Meadow · high"), ("beach", "Beach · medium")]
  /// each theme's own sub-choice (Wind Map's region, Lava Lamp's colours, …), declared in themes/variants.json
  static var variantOverride: String?
  static func variant(_ t: String) -> String? { (t == theme ? variantOverride : nil) ?? d.string(forKey: "variant.\(t)") ?? (t == "wind" ? homeRegion : nil)
    ?? (t == "tunnel" && (DeskIcons.shared?.known == true ? !(DeskIcons.shared?.icons.isEmpty ?? true) : d.bool(forKey: "iconsPresent")) ? "none" : nil) }   // Wind Tunnel with no model chosen: your desktop icons, when you have some
  /// where the user is, roughly: the city of their time zone, from the system's time-zone table (no location permission)
  static let site: (name: String, lat: Double, lon: Double, tz: String, cc: String)? = {
    let tz = TimeZone.current.identifier
    guard let tab = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8) else { return nil }
    for line in tab.split(separator: "\n") where !line.hasPrefix("#") {
      let f = line.split(separator: "\t"); guard f.count >= 3, f[2] == tz else { continue }
      // "+2232+08822" or "+404251-0740023": ±DDMM[SS] then ±DDDMM[SS]
      let c = String(f[1]); guard let split = c.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
      func deg(_ s: Substring, _ dd: Int) -> Double {
        let sign: Double = s.first == "-" ? -1 : 1, n = s.dropFirst(), d = Double(n.prefix(dd)) ?? 0, m = Double(n.dropFirst(dd).prefix(2)) ?? 0, sec = Double(n.dropFirst(dd + 2).prefix(2)) ?? 0
        return sign * (d + m / 60 + sec / 3600) }
      let name = tz.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? tz
      return (name, deg(c[c.startIndex..<split], 2), deg(c[split...], 3), tz, String(f[0]))
    }
    return nil
  }()
  /// the site as URL parameters for a theme page
  static var siteQuery: String {
    guard let s = site else { return "" }
    let e = { (v: String) in v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
    return "&site=\(e(s.name))&lat=\(String(format: "%.3f", s.lat))&lon=\(String(format: "%.3f", s.lon))&tz=\(e(s.tz))"
  }
  /// Wind Map's default region: the user's own country, if the map has it
  static let homeRegion: String? = {
    guard let cc = site?.cc, let name = Locale(identifier: "en_US").localizedString(forRegionCode: cc),
          let data = try? Data(contentsOf: themesRoot.appendingPathComponent("variants.json")),
          let man = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let wind = man["wind"] as? [String: Any] else { return nil }
    let opts = (wind["groups"] as? [[String: Any]] ?? []).flatMap { $0["options"] as? [[String: Any]] ?? [] }
    func norm(_ s: String) -> String { s.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter } }
    return (opts.first { norm($0["name"] as? String ?? "") == norm(name) } ?? opts.first { norm($0["name"] as? String ?? "").hasPrefix(norm(name)) || norm(name).hasPrefix(norm($0["name"] as? String ?? "")) })?["id"] as? String
  }()
  static func setVariant(_ t: String, _ v: String) { variantOverride = nil; d.set(v, forKey: "variant.\(t)") }
  /// how far (pt) the land / cloud bank reaches past each window edge
  static var margin: Double { get { (d.object(forKey: "margin") as? Double).flatMap { $0.isFinite ? min(400, max(0, $0)) : nil } ?? 140 } set { d.set(newValue, forKey: "margin") } }
  static var fps: Double { get { (d.object(forKey: "fps") as? Double).flatMap { $0.isFinite ? min(120, max(0, $0)) : nil } ?? 0 } set { d.set(newValue, forKey: "fps") } }
  /// seeds the generated names (your walker, the strangers); stable across launches
  static var seed: Int { if let v = d.object(forKey: "seed") as? Int { return v }; let v = Int.random(in: 1..<Int(Int32.max)); d.set(v, forKey: "seed"); return v }
  /// pause the animation when nobody has touched the mouse or keyboard for a while; any input brings it straight back
  /// check for, download and install updates on its own (installs while the screen is locked); off = only "Check for Updates…"
  /// the newest version whose What's New you've seen (nil: none yet; a fresh install starts at its own version)
  static var notesSeen: String? { get { d.string(forKey: "notesSeen") } set { d.set(newValue, forKey: "notesSeen") } }
  static var hasNewNotes: Bool { notesSeen.map { Updater.newer(version, than: $0) } ?? true }
  /// the release notes: CHANGELOG.md, bundled beside the themes (or the repo's, in a development build)
  static var changelog: String {
    let cands = [Bundle.main.resourceURL?.appendingPathComponent("CHANGELOG.md"), themesRoot.deletingLastPathComponent().appendingPathComponent("CHANGELOG.md")]
    for c in cands.compactMap({ $0 }) { if let t = try? String(contentsOf: c, encoding: .utf8) { return t } }
    return ""
  }
  /// make room for desktop icons (reading where they are needs macOS's one-time "control Finder" permission)
  static var deskIcons: Bool { get { d.bool(forKey: "deskIcons") } set { d.set(newValue, forKey: "deskIcons") } }
  static var autoUpdate: Bool { get { d.object(forKey: "autoUpdate") as? Bool ?? true } set { d.set(newValue, forKey: "autoUpdate") } }
  static var restWhenIdle: Bool { get { d.object(forKey: "restWhenIdle") as? Bool ?? true } set { d.set(newValue, forKey: "restWhenIdle") } }
  /// minutes without input before the wallpaper rests (0: never); before this setting existed it was on/off at 3
  static var idleMinutes: Double {
    get { (d.object(forKey: "idleMinutes") as? Double).flatMap { $0.isFinite ? min(120, max(0, $0)) : nil } ?? (restWhenIdle ? 3 : 0) }
    set { d.set(newValue, forKey: "idleMinutes"); restWhenIdle = newValue > 0; if newValue > 0 { d.set(newValue, forKey: "idleLast") } } }
  static var idleLast: Double { (d.object(forKey: "idleLast") as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 3 }
  /// what the scene reshapes itself around: your windows, Stage Manager's thumbnails, desktop widgets; and whether it
  /// reacts to the pointer. Off: the wallpaper carries on as if that weren't there.
  static func flag(_ k: String, _ def: Bool = true) -> Bool { d.object(forKey: k) as? Bool ?? def }
  static var reactWindows: Bool { get { flag("reactWindows") } set { d.set(newValue, forKey: "reactWindows") } }
  static var reactStage: Bool { get { flag("reactStage") } set { d.set(newValue, forKey: "reactStage") } }
  static var reactWidgets: Bool { get { flag("reactWidgets") } set { d.set(newValue, forKey: "reactWidgets") } }
  static var reactCursor: Bool { get { flag("reactCursor") } set { d.set(newValue, forKey: "reactCursor") } }
  /// on battery: 0 the same, 1 calmer (half the frame rate), 2 paused
  static var battery: Int { get { (d.object(forKey: "battery") as? Int).map { min(2, max(0, $0)) } ?? 0 } set { d.set(newValue, forKey: "battery") } }
  static var mask: Bool { get { d.object(forKey: "mask") as? Bool ?? false }   /* every theme opts out of the mask now */ set { d.set(newValue, forKey: "mask") } }
}

let args = CommandLine.arguments
func argValue(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let benchMode = args.contains("--bench")
let stock = args.contains("--stock")   // baseline: native dpr, theme's own pacing, no mask
let themesRoot: URL = {
  if let p = argValue("--themes") { return URL(fileURLWithPath: p).standardized }
  return Bundle.main.resourceURL!.appendingPathComponent("themes").standardized
}()
if let v = argValue("--fps") { Cfg.fps = Double(v)! }
if let v = argValue("--variant") { Cfg.variantOverride = v }
if let v = argValue("--theme") { Cfg.themeOverride = v }
if let v = argValue("--mask") { Cfg.mask = v == "1" }
if let v = argValue("--margin") { Cfg.margin = Double(v)! }
Cfg.migrate()
if args.contains("--print-site") { print(Cfg.site.map { "\($0.name) \($0.lat),\($0.lon) \($0.cc)" } ?? "none", Cfg.homeRegion ?? "-"); exit(0) }   // dev
if args.contains("--install-login-item") { LoginItem.set(true); print(LoginItem.plist.path); exit(0) }
if stock { Cfg.mask = false }

func log(_ s: String) { print(s); fflush(stdout) }
// The released app always keeps a log at ~/Library/Logs/Tidewall.log (the LaunchAgent sends it there; opened from
// Finder, stdout went nowhere, so a crash left no trace): what it did last, and how it died, if it ever does
if Bundle.main.bundleIdentifier != nil && !benchMode {
  var st = stat()
  if fstat(STDOUT_FILENO, &st) != 0 || (st.st_mode & S_IFMT) != S_IFREG {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // opened first, swapped in only if that worked (a failed freopen would leave fd 1 free for whatever opens next)
    let fd = open(dir.appendingPathComponent("Tidewall.log").path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    if fd >= 0 { fflush(stdout); dup2(fd, STDOUT_FILENO); dup2(fd, STDERR_FILENO); close(fd) }
  }
}
// start over once it passes 5 MB
if var st = Optional(stat()), fstat(STDOUT_FILENO, &st) == 0, st.st_size > 5_000_000, (st.st_mode & S_IFMT) == S_IFREG { ftruncate(STDOUT_FILENO, 0) }
// how it died: an Objective-C exception (its reason and where), or a crash signal (a Swift trap, a bad pointer) with a
// stack, before the system's own crash report.
// AppKit catches exceptions thrown while it handles a click or a menu, logs them and carries on in whatever state they
// left behind; crash on them instead, so they come here (and to the system report) like any other
UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
NSSetUncaughtExceptionHandler { e in
  log("CRASH exception \(e.name.rawValue): \(e.reason ?? "") (Tidewall \(Cfg.version))\n" + e.callStackSymbols.prefix(40).joined(separator: "\n")) }
// The signal handler runs when memory may be corrupt (the allocator's lock held, say): everything it touches is made
// here, ahead of time, and it allocates nothing. It writes the stack, then returns: its handler is reset as it runs,
// so the faulting instruction runs again and the process dies of the original fault (the system report shows it).
let crashHead: UnsafeMutablePointer<CChar> = strdup("CRASH signal (Tidewall); stack:\n")
let crashFrames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)
_ = backtrace(crashFrames, 64)                                          // loads what backtrace needs now, not mid-crash
do {
  var alt = stack_t(); alt.ss_size = 1 << 16; alt.ss_sp = UnsafeMutableRawPointer.allocate(byteCount: 1 << 16, alignment: 16); alt.ss_flags = 0
  sigaltstack(&alt, nil)                                                // a stack overflow still gets its log line
  for sig in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
    var sa = sigaction()
    sa.__sigaction_u.__sa_handler = { _ in
      _ = write(STDOUT_FILENO, crashHead, strlen(crashHead))
      backtrace_symbols_fd(crashFrames, backtrace(crashFrames, 64), STDOUT_FILENO)
    }
    sa.sa_flags = SA_RESETHAND | SA_ONSTACK
    sigaction(sig, &sa, nil)
  }
}

// MARK: - Theme pages over a private scheme (file:// gives opaque origins → tainted canvases)

final class SchemeHandler: NSObject, WKURLSchemeHandler {
  static let types = ["html": "text/html", "js": "text/javascript", "json": "application/json", "png": "image/png",
                      "webp": "image/webp", "css": "text/css", "svg": "image/svg+xml", "glb": "model/gltf-binary",
                      "wasm": "application/wasm", "jpg": "image/jpeg", "jpeg": "image/jpeg", "bin": "application/octet-stream"]
  func webView(_ w: WKWebView, start t: WKURLSchemeTask) {
    guard let url = t.request.url else { return }
    let f = themesRoot.appendingPathComponent(String(url.path.dropFirst())).standardized
    guard f.path.hasPrefix(themesRoot.path + "/"), let data = try? Data(contentsOf: f) else {
      t.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)); return
    }
    let mime = Self.types[f.pathExtension.lowercased()] ?? "application/octet-stream"
    t.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
    t.didReceive(data); t.didFinish()
  }
  func webView(_ w: WKWebView, stop t: WKURLSchemeTask) {}
}

/// Runs before any page script.
func earlyScript(fps: Double, opaque: Bool, cap: Double = 8) -> String { """
(() => {
  // the theme's sharpness cap: the page sees a devicePixelRatio no higher than it (the host scales its messages the same)
  if (\(cap) < 8) {
    const pd = Object.getOwnPropertyDescriptor(window, 'devicePixelRatio') || Object.getOwnPropertyDescriptor(Window.prototype, 'devicePixelRatio');
    const real = pd && pd.get ? () => pd.get.call(window) : () => 2;
    try { Object.defineProperty(window, 'devicePixelRatio', { get: () => Math.min(real(), \(cap)), configurable: true }); } catch (_) {}
  }
  const post = m => webkit.messageHandlers.host.postMessage(m);
  // A WebGL page whose GPU context is lost (displays sleeping and waking, external monitors reconnecting, a GPU
  // switch) is left showing only its CSS background, for good. Watch every WebGL canvas on the page: when one is
  // lost, tell the host and reload, unless the context comes back by itself first (then reload at once: its
  // textures and buffers are gone either way). Only canvases in the document count; contexts are held weakly.
  (() => {
    const gc = HTMLCanvasElement.prototype.getContext, all = [];
    let t = 0;
    const lost = () => {
      try { webkit.messageHandlers.host.postMessage('JSERR webgl context lost; reloading the page'); } catch (_) {}
      // a page that keeps losing it waits longer each time: one loss can never turn into a reload loop
      let n = 0; try { const r = JSON.parse(sessionStorage.__twLost || '[]').filter(x => Date.now() - x < 120000); r.push(Date.now()); sessionStorage.__twLost = JSON.stringify(r); n = r.length; } catch (_) {}
      clearTimeout(t); t = setTimeout(() => location.reload(), n > 3 ? 30000 : n > 1 ? 8000 : 2500);
    };
    HTMLCanvasElement.prototype.getContext = function (type, ...a) {
      const ctx = gc.call(this, type, ...a);
      if (ctx && String(type).indexOf('webgl') === 0 && !this.__twWatched) {
        this.__twWatched = true; all.push(new WeakRef(this));
        this.addEventListener('webglcontextlost', e => { if (!this.isConnected) return; e.preventDefault(); lost(); });
        this.addEventListener('webglcontextrestored', () => { if (!this.isConnected) return; clearTimeout(t); location.reload(); });
      }
      return ctx;
    };
    // the host asks after the displays wake: is any visible WebGL canvas without its context?
    window.__twGLLost = () => all.some(r => { const c = r.deref(); if (!c || !c.isConnected) return false;
      const g = gc.call(c, 'webgl2') || gc.call(c, 'webgl'); return !!(g && g.isContextLost()); });
  })();
  // WebView2 surface the pages expect
  const ls = [];
  window.chrome = window.chrome || {};
  window.chrome.webview = { postMessage: m => post(typeof m === 'string' ? m : JSON.stringify(m)),
    addEventListener: (t, f) => { if (t === 'message') ls.push(f); }, removeEventListener: () => {} };
  window.__hostSend = s => { for (const f of ls) f({ data: s }); };
  addEventListener('error', e => post('JSERR ' + e.message + ' ' + (e.filename || '').split('/').pop() + ':' + e.lineno));
  window.__opaque = \(opaque);
  if (\(args.contains("--profile"))) window.__prof = { n: 0, ms: 0, t0: performance.now() };
  // Lever 3: ask for a stencil buffer, keep the theme's GL context for the mask.
  const gc = HTMLCanvasElement.prototype.getContext;
  HTMLCanvasElement.prototype.getContext = function (type, opts) {
    if (type === 'webgl2' && !window.__gl) {
      // opaque: the scene covers every pixel anyway; an opaque layer lets WindowServer copy instead of blend
      // low-power: on Macs with two GPUs, a wallpaper must never wake the discrete one (it would hold it on, and drain the battery)
      const g = gc.call(this, type, Object.assign({}, opts, { stencil: false, depth: false, alpha: window.__opaque === false, powerPreference: 'low-power' }));   // no theme uses depth or the stencil mask: no buffers for them
      window.__gl = g; return g;
    }
    return gc.call(this, type, String(type).indexOf('webgl') === 0 ? Object.assign({ powerPreference: 'low-power' }, opts) : opts);
  };
  // Frame pacing. Left alone, every page would draw at the display's refresh (120 Hz on ProMotion) and the slow,
  // ambient ones would wake 120 times a second just to skip most of those frames. So every page runs at a calm
  // 30 fps, and at 60 while you're working near it (the cursor over its display, a window being dragged), so what
  // follows you and your windows stays smooth. A slow scene may ask for less while calm (window.__twCalm: slow ships,
  // wax, gardeners). A frame rate picked in Settings replaces all of it. Between frames the
  // page sleeps on a timer instead of waking at every vsync.
  // a picked rate: 60 holds every scene there; 30, 20 or 15 cap it (a calm scene that asks for less still gets less)
  const pick = \(fps), CALM = pick > 0 ? pick : 30, LIVE = pick > 0 ? pick : 60, calmAt = () => pick >= 60 ? pick : Math.min(CALM, window.__twCalm || CALM);
  let boostUntil = 0, paceK = 1;                                      // paceK: 2 on battery when Settings says calmer
  window.__twBoost = ms => { const u = performance.now() + ms; if (u > boostUntil) boostUntil = u; };
  { const deliver = window.__hostSend;
    window.__hostSend = s => { if (s.startsWith('{"t":"pace"')) { paceK = +JSON.parse(s).k || 1; return; }
      const cur = s.startsWith('{"t":"cursor"') && s.charCodeAt(13) === 44;   // the pointer, not cursorOff
      if (s.startsWith('{"t":"dicons"')) window.__dicons = s;            // (kept for the bench probes)
      if (cur) window.__twOver = s.indexOf('"w":1') >= 0;
      if ((cur && !window.__twOver) || window.__live) window.__twBoost(900); deliver(s); }; }   // the pointer over the wallpaper ({"t":"cursor…, not over a window), or a live drag
  const raf = window.requestAnimationFrame.bind(window);
  let due = 0, lastT = -1, go = false;
  window.requestAnimationFrame = cb => raf(function tick(t) {
    if (t !== lastT) { lastT = t; const iv = paceK * 1000 / (performance.now() < boostUntil ? LIVE : calmAt()); go = t + 2 >= due; if (go) due = Math.max(due + iv, t); }
    if (!go) { const wait = due - t - 6; if (wait > 4) setTimeout(() => raf(tick), wait); else raf(tick); return; }
    if (window.__prof) { const a = performance.now(); cb(t); const p = window.__prof; p.n++; p.ms += performance.now() - a; } else cb(t);
  });
})();
""" }

/// Filming in slow motion (--timescale k): the page's clocks all run k× slower, so frames can be taken at a pace that
/// plays back smooth at real speed
func timescaleScript(_ k: Double) -> String { """
(() => {
  const k = \(k), pn = performance.now.bind(performance), t0 = pn();
  performance.now = () => t0 + (pn() - t0) * k;
  const dn = Date.now, d0 = dn(); Date.now = () => d0 + (dn() - d0) * k;
  const raf = window.requestAnimationFrame.bind(window);
  window.requestAnimationFrame = cb => raf(t => cb(t0 + (t - t0) * k));
  const st = window.setTimeout.bind(window), si = window.setInterval.bind(window);
  window.setTimeout = (f, d, ...a) => st(f, (d || 0) / k, ...a); window.setInterval = (f, d, ...a) => si(f, (d || 0) / k, ...a);
  const slow = () => { try { for (const a of document.getAnimations()) if (a.playbackRate !== k) a.playbackRate = k; } catch (_) {} raf(slow); }; raf(slow);
})();
""" }

/// Runs after the page's own scripts (globals FA/FB/commit/refresh/icons exist).
let lateScript = """
(() => {
  const gl = window.__gl; if (!gl) return;
  // Lever 2: live drags snap the field; anything else keeps the theme's own slow morph.
  window.__live = false;
  const commit0 = commit;
  commit = function (fromEmpty) { if (window.__live && !fromEmpty && FB) { refresh(); return; } return commit0(fromEmpty); };
  if (window.__noMask) { webkit.messageHandlers.host.postMessage('patched'); return; }
  // Lever 3: stencil out the windows (canvas px rects [x0,y0,x1,y1]).
  const vs = `#version 300 es
  uniform vec4 uR[64]; uniform vec2 uView;
  void main() {
    int r = gl_VertexID / 6, v = gl_VertexID % 6;
    vec2 c = vec2(v == 1 || v == 4 || v == 5 ? 1.0 : 0.0, v == 2 || v == 3 || v == 5 ? 1.0 : 0.0);
    vec4 q = uR[r];
    vec2 p = mix(q.xy, q.zw, c) / uView * 2.0 - 1.0;
    gl_Position = vec4(p.x, -p.y, 0.0, 1.0);
  }`;
  const fs = `#version 300 es
  precision lowp float; out vec4 o; void main() { o = vec4(0.0); }`;
  const sh = (t, s) => { const x = gl.createShader(t); gl.shaderSource(x, s); gl.compileShader(x); return x; };
  const prog = gl.createProgram();
  gl.attachShader(prog, sh(gl.VERTEX_SHADER, vs)); gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, fs)); gl.linkProgram(prog);
  const uR = gl.getUniformLocation(prog, 'uR'), uView = gl.getUniformLocation(prog, 'uView');
  let rects = new Float32Array(0), n = 0;
  window.__setMask = list => {   // CSS px
    const k = devicePixelRatio; n = Math.min(list.length, 64); rects = new Float32Array(n * 4);
    list.slice(0, n).forEach((r, i) => rects.set([r[0] * k, r[1] * k, r[2] * k, r[3] * k], i * 4));
  };
  let fb = null;
  const bindFb = gl.bindFramebuffer.bind(gl);
  gl.bindFramebuffer = (t, f) => { if (t === gl.FRAMEBUFFER || t === gl.DRAW_FRAMEBUFFER) fb = f; bindFb(t, f); };
  const draw0 = gl.drawArrays.bind(gl);
  let lastWrite = -1e9;
  gl.drawArrays = (mode, first, count) => {
    if (fb || !n) { if (!fb) gl.disable(gl.STENCIL_TEST); return draw0(mode, first, count); }
    const now = performance.now();
    if (now - lastWrite > 8) {      // first draw of a frame: the stencil was cleared with the drawing buffer → rewrite it
      lastWrite = now;
      const p = gl.getParameter(gl.CURRENT_PROGRAM);
      const sc = gl.isEnabled(gl.SCISSOR_TEST); if (sc) gl.disable(gl.SCISSOR_TEST);
      gl.enable(gl.STENCIL_TEST);
      gl.clearStencil(0); gl.clear(gl.STENCIL_BUFFER_BIT);
      gl.stencilFunc(gl.ALWAYS, 1, 0xff); gl.stencilOp(gl.KEEP, gl.KEEP, gl.REPLACE);
      gl.colorMask(false, false, false, false);
      gl.useProgram(prog); gl.uniform4fv(uR, rects); gl.uniform2f(uView, gl.drawingBufferWidth, gl.drawingBufferHeight);
      draw0(gl.TRIANGLES, 0, n * 6);
      gl.colorMask(true, true, true, true);
      gl.useProgram(p); if (sc) gl.enable(gl.SCISSOR_TEST);
    }
    gl.enable(gl.STENCIL_TEST);
    gl.stencilFunc(gl.EQUAL, 0, 0xff); gl.stencilOp(gl.KEEP, gl.KEEP, gl.KEEP);
    draw0(mode, first, count);
  };
  webkit.messageHandlers.host.postMessage('patched');
})();
"""

/// WebKit caps page rendering near 60 fps by default; on a 120 Hz display that makes the wallpaper trail a
/// dragged window. Flip the internal feature off (private API, guarded: does nothing if it ever disappears).
func unlockHighRefresh(_ prefs: WKPreferences) {
  let cls: AnyClass = WKPreferences.self
  guard let featuresSel = Optional(NSSelectorFromString("_features")), (cls as AnyObject).responds(to: featuresSel),
        let list = (cls as AnyObject).perform(featuresSel)?.takeUnretainedValue() as? [NSObject] else { log("high-refresh: no _features"); return }
  let setSel = NSSelectorFromString("_setEnabled:forFeature:")
  guard prefs.responds(to: setSel), let imp = class_getMethodImplementation(type(of: prefs), setSel) else { log("high-refresh: no setter"); return }
  typealias SetFn = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
  let set = unsafeBitCast(imp, to: SetFn.self)
  for f in list where (f.value(forKey: "key") as? String) == "PreferPageRenderingUpdatesNear60FPSEnabled" { set(prefs, setSel, false, f); log("high-refresh: unlocked") }
}

// MARK: - One wallpaper per screen

/// What a screen shows while its page is let go: the last frame, as a still picture (a few MB, no web process at all)
final class StillWall {
  let window: NSWindow
  init(frame: NSRect, image: NSImage) {
    window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
    window.ignoresMouseEvents = true; window.isOpaque = true; window.hasShadow = false; window.isReleasedWhenClosed = false
    // one bitmap, handed straight to the layer (an image view would keep extra copies of the picture)
    let v = NSView(frame: NSRect(origin: .zero, size: frame.size)); v.wantsLayer = true
    var r = NSRect(origin: .zero, size: image.size); v.layer?.contents = image.cgImage(forProposedRect: &r, context: nil, hints: nil); v.layer?.contentsGravity = .resize
    window.contentView = v; window.setFrame(frame, display: true); window.orderFront(nil)
  }
  func close() { window.orderOut(nil); window.close() }
}

final class Wallpaper: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  let screenID: CGDirectDisplayID
  /// the pages showing now: a new one joins their web process (one process for every display, theme after theme)
  static let live = NSHashTable<WKWebView>.weakObjects()
  var cgFrame: CGRect                         // screen in CG global coords (top-left origin), points
  let window: NSWindow
  let web: WKWebView
  var ready = false
  var paused: Bool?
  var lastIcons = "", lastMask = "", lastWins = ""
  var pending: (() -> Void)?
  var onShown: (() -> Void)?                  // called once a page that started hidden has drawn and is on show

  init(screen: NSScreen, hidden: Bool = false, fakeID: CGDirectDisplayID? = nil, fakeFrame: CGRect? = nil) {
    screenID = fakeID ?? screen.displayID
    cgFrame = fakeFrame ?? screen.cgFrame
    cap = min(stock ? 8 : CGFloat(Cfg.renderCap(Cfg.theme(for: fakeID ?? screen.displayID))), fakeID.flatMap { fakeScale[$0] } ?? 8)   // (a pretend 1× monitor draws at 1×)
    let winRect = fakeFrame.map { NSRect(x: screen.frame.minX, y: screen.frame.minY, width: $0.width, height: $0.height) } ?? screen.frame
    let cfg = WKWebViewConfiguration()
    // every screen's page in ONE web process: the engine, its libraries and caches are paid for once, not per display
    if let r = Wallpaper.live.allObjects.first, cfg.responds(to: NSSelectorFromString("_setRelatedWebView:")) { cfg.perform(NSSelectorFromString("_setRelatedWebView:"), with: r) }
    cfg.setURLSchemeHandler(SchemeHandler(), forURLScheme: "tidewall")
    cfg.suppressesIncrementalRendering = true
    unlockHighRefresh(cfg.preferences)

    let ucc = cfg.userContentController
    if let k = argValue("--timescale").flatMap(Double.init), k != 1 { ucc.addUserScript(WKUserScript(source: timescaleScript(k), injectionTime: .atDocumentStart, forMainFrameOnly: true)) }
    ucc.addUserScript(WKUserScript(source: earlyScript(fps: stock ? 0 : Cfg.fps, opaque: !stock && !args.contains("--no-opaque"), cap: Double(cap)), injectionTime: .atDocumentStart, forMainFrameOnly: true))
    ucc.addUserScript(WKUserScript(source: lateScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    window = fakeFrame != nil ? FreeSizeWindow(contentRect: winRect, styleMask: .borderless, backing: .buffered, defer: false)   // dev: a pretend display's own size
      : NSWindow(contentRect: winRect, styleMask: .borderless, backing: .buffered, defer: false)
    window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
    window.ignoresMouseEvents = true
    window.isOpaque = true
    window.backgroundColor = NSColor(red: 0.914, green: 0.847, blue: 0.706, alpha: 1)
    window.hasShadow = false
    window.isReleasedWhenClosed = false
    web = WKWebView(frame: NSRect(origin: .zero, size: winRect.size), configuration: cfg)
    Wallpaper.live.add(web)
    web.setValue(false, forKey: "drawsBackground")
    super.init()
    ucc.add(WeakHandler(self), name: "host")
    web.navigationDelegate = self
    if benchMode {   // tests: keep animating even when the desktop isn't on screen (private, guarded)
      let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
      if web.responds(to: sel), let imp = class_getMethodImplementation(type(of: web), sel) {
        typealias F = @convention(c) (AnyObject, Selector, Bool) -> Void; unsafeBitCast(imp, to: F.self)(web, sel, false) }
    }
    window.contentView = web
    window.setFrame(winRect, display: false)
    if hidden { window.alphaValue = 0 }      // built behind the still picture; shown once it has drawn
    window.orderFront(nil)
    load()
  }

  func load() {
    ready = false; paused = nil; lastIcons = ""; lastMask = ""; lastWins = ""; wantsCursor = true; seenSince = nil
    let page = ["beach": "flat", "meadow": "meadow", "inkmap": "inkmap", "celestial": "celestial", "snow": "snow", "reef": "reef", "wind": "wind", "lava": "lava", "tunnel": "tunnel", "gallery": "gallery", "garden": "garden", "railway": "railway"][Cfg.theme(for: screenID)] ?? "estate"
    loadedVariant = Cfg.variant(Cfg.theme(for: screenID))
    let v = loadedVariant.flatMap { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) }.map { "&v=\($0)" } ?? ""
    web.load(URLRequest(url: URL(string: "tidewall://app/\(page).html?wallpaper=1\(v)\(Cfg.siteQuery)")!))
  }

  private(set) var loadedVariant: String?   // what the page was opened with (Wind Tunnel's automatic choice can change under it)
  var realRects: [CGRect] = []              // every window over this screen (the scene may be told about fewer)
  var seenSince: Double?                    // when it first ran on show (a picture of it a few seconds on shows the scene)
  private var wasOver = false, lastOverSend = 0.0
  /// pages draw at their own pace × k (2 on battery when Settings says calmer)
  func sendPace() { guard ready else { return }; send("{\"t\":\"pace\",\"k\":\(delegate.paceK)}") }
  var wantsCursor = true                    // a theme that ignores the pointer says so ("nocursor"): no 120 Hz messages for it
  /// where this screen sits among all of them (points, top-left origin): themes continue one world across displays
  /// (the sky, the map, the painted panorama) and never repeat the same thing on every screen
  func sendDesk() {
    let spanning = Cfg.spanThemes.contains(Cfg.theme(for: screenID))
    var frames = spanning ? worldFrames(for: screenID) : allFrames(), me = cgFrame
    let mainFrame = fakeWorld.isEmpty ? (NSScreen.screens.first?.cgFrame ?? cgFrame) : CGRect(origin: .zero, size: NSScreen.screens.first?.frame.size ?? .zero)
    var main = frames.first { $0 == mainFrame } ?? frames.first ?? cgFrame
    if let f = argValue("--fakedesk"), let i = Int(f) {   // bench: pretend to be screen i of a three-screen desk (external | built-in | external)
      let b = cgFrame; frames = [CGRect(x: b.minX - 1920, y: b.minY - 98, width: 1920, height: 1080), b, CGRect(x: b.maxX, y: b.minY - 98, width: 1920, height: 1080)]
      if args.contains("--stacked") {                    // two monitors side by side above the laptop, as on this Mac
        frames = [CGRect(x: b.minX - 1533, y: b.minY - 1080, width: 1920, height: 1080), CGRect(x: b.minX + 387, y: b.minY - 1080, width: 1920, height: 1080), b] }
      main = b; me = frames[min(frames.count - 1, max(0, i))]
    }
    let u = frames.reduce(frames.first ?? me) { $0.union($1) }
    // reading order: rows (screens that overlap vertically) from the top, left to right within a row
    var rows: [[CGRect]] = []
    for f in frames.sorted(by: { $0.midY < $1.midY }) {
      if let r = rows.firstIndex(where: { $0.contains { min($0.maxY, f.maxY) - max($0.minY, f.minY) > 40 } }) { rows[r].append(f) } else { rows.append([f]) } }
    let order = rows.flatMap { $0.sorted { $0.minX < $1.minX } }, i = order.firstIndex(of: me) ?? 0
    lastDeskWorld = frames.count
    let fr = frames.map { "[\(Int($0.minX - u.minX)),\(Int($0.minY - u.minY)),\(Int($0.width)),\(Int($0.height))]" }.joined(separator: ",")
    let deskMsg = "{\"t\":\"desk\",\"fr\":[\(fr)],\"x\":\(me.minX - u.minX),\"y\":\(me.minY - u.minY),\"w\":\(me.width),\"h\":\(me.height),\"uw\":\(u.width),\"uh\":\(u.height),\"i\":\(i),\"n\":\(frames.count),\"mx\":\(main.midX - u.minX),\"my\":\(main.midY - u.minY),\"mw\":\(main.width),\"mh\":\(main.height)}"
    send(deskMsg)
    if deskMsg != lastDeskMsg { lastDeskMsg = deskMsg; lastDIcons = ""; sendDeskIcons() }   // (pages place icons by their world offset: a new desk may have moved it)
  }
  private(set) var lastDeskWorld = 1
  private var lastDeskMsg = ""
  private var lastDIcons = ""
  /// the desktop icons this page should make room for (those on its display, or anywhere in its world), each icon and
  /// each cluster of neighbouring icons, in its own device pixels; an empty list when the setting is off
  func sendDeskIcons() {
    guard ready, let di = DeskIcons.shared else { return }
    let world = Cfg.spanThemes.contains(Cfg.theme(for: screenID)) ? worldFrames(for: screenID) : [cgFrame]
    let k = scale, o = cgFrame.origin
    func enc(_ rs: [CGRect]) -> String { rs.filter { r in world.contains { $0.intersects(r) } }.map { r in let q = r.offsetBy(dx: -o.x, dy: -o.y)
      return "[\(Int(q.minX * k)),\(Int(q.minY * k)),\(Int(q.maxX * k)),\(Int(q.maxY * k))]" }.joined(separator: ",") }
    let msg = "{\"t\":\"dicons\",\"r\":[\(enc(di.icons))],\"c\":[\(enc(di.clusters))],\"i\":[\(enc(di.images))]}"
    if msg != lastDIcons { lastDIcons = msg; send(msg) }
  }
  /// the page's pixels per point: the display's, but no more than its theme is drawn at (what its devicePixelRatio says)
  let cap: CGFloat                            // fixed when the page is made: the same number its devicePixelRatio was given
  var scale: CGFloat { min(window.backingScaleFactor, cap) }
  func cursor(_ p: CGPoint) {
    guard wantsCursor, Cfg.reactCursor else { return }
    let k = scale
    // over one of your windows (you're working in an app, not looking at the wallpaper): the page still learns where
    // the pointer is, but doesn't speed up for it
    let over = realRects.contains { $0.contains(p) }
    // over a window (you're working in an app): the page hears where the pointer is 10 times a second, not 60; nothing
    // it does there can be seen, and every message is work for it
    let now = ProcessInfo.processInfo.systemUptime
    if over && wasOver && now - lastOverSend < 0.1 { return }
    wasOver = over; if over { lastOverSend = now }
    send("{\"t\":\"cursor\",\"x\":\(Int((p.x - cgFrame.minX) * k)),\"y\":\(Int((p.y - cgFrame.minY) * k))\(over ? ",\"w\":1" : "")}")
  }

  func close() { Wallpaper.live.remove(web); web.stopLoading(); window.orderOut(nil); window.close() }

  func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
    let s = "\(m.body)"
    if s == "nocursor" { wantsCursor = false; return }
    if s == "ready" && window.alphaValue < 1 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in guard let self else { return }
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.35; self.window.animator().alphaValue = 1 } completionHandler: { self.onShown?(); self.onShown = nil } }
    }
    if s == "ready" { ready = true; lastWins = ""; lastIcons = ""; lastMask = ""; lastDIcons = ""; lastDeskMsg = ""; paused = nil   // a reloaded page has none of it
      sendDesk(); send("{\"t\":\"me\",\"seed\":\(Cfg.seed)}"); sendDeskIcons(); if delegate.paceK != 1 { sendPace() }
      if let p = pending { pending = nil; p() } else if let a = lastArgs { update(rects: a.0, owners: a.1, live: false, pause: a.3) }
      return }
    if s.hasPrefix("JSERR") || s == "patched" || (s.hasPrefix("STAT") && ProcessInfo.processInfo.environment["TIDEWALL_STAT"] != nil) { log("[\(screenID)] \(s)") }
  }
  private var crashes: [Double] = []
  func webViewWebContentProcessDidTerminate(_ w: WKWebView) {
    let now = ProcessInfo.processInfo.systemUptime; crashes = crashes.filter { now - $0 < 60 } + [now]
    let wait = crashes.count > 2 ? 10.0 : 0          // crashing over and over: give the system a moment
    log("[\(screenID)] web process died; reloading\(wait > 0 ? " in \(Int(wait)) s" : "")")
    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.load() }
  }

  func send(_ json: String, live: Bool = false) {
    guard ready else { return }
    let lit = String(data: try! JSONSerialization.data(withJSONObject: [json]), encoding: .utf8)!
    web.evaluateJavaScript("window.__live=\(live);window.__hostSend(\(lit)[0]);window.__live=false;null", completionHandler: nil)
  }

  /// A paused page whose screen changed size has had its canvas cleared by the resize and won't draw until it's
  /// resumed (a black or half-blank screen, which the away still could then capture): let it run for a moment to
  /// redraw at the new size, then pause it again.
  func redrawIfPaused() {
    guard paused == true else { return }
    paused = false; send("{\"t\":\"pause\",\"v\":false}")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self, self.lastArgs?.3 == true, self.paused == false else { return }
      self.paused = true; self.send("{\"t\":\"pause\",\"v\":true}") }
  }
  /// rects: windows on this screen in CG global points
  private var lastArgs: ([CGRect], [String], Bool, Bool)?
  func update(rects: [CGRect], owners: [String], live: Bool, pause: Bool) {
    lastArgs = (rects, owners, live, pause)
    guard ready else { pending = { [weak self] in self?.update(rects: rects, owners: owners, live: live, pause: pause) }; return }
    // a page that's paused before it ever laid out (relaunched while paused, or a theme changed while paused) lays out
    // around your windows once, draws, and only then pauses: otherwise it would freeze a scene that ignores them
    let firstLayout = lastWins.isEmpty
    if pause && !firstLayout { if paused != true { paused = true; send("{\"t\":\"pause\",\"v\":true}") }; return }
    if !pause && paused != false { paused = false; send("{\"t\":\"pause\",\"v\":false}") }
    if pause && firstLayout {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
        guard let self, self.lastArgs?.3 == true, self.paused != true else { return }
        self.paused = true; self.send("{\"t\":\"pause\",\"v\":true}") }
    }
    let k = scale, m = Cfg.margin, o = cgFrame.origin
    let local = rects.map { $0.offsetBy(dx: -o.x, dy: -o.y) }
    let icons = local.map { r -> String in
      let q = r.insetBy(dx: -m, dy: -m)
      return "[\(Int(q.minX * k)),\(Int(q.minY * k)),\(Int(q.maxX * k)),\(Int(q.maxY * k))]"
    }.joined(separator: ",")
    // raw window rects + app names (themes that draw *around* the real window edge, e.g. Estate)
    let raw = local.map { "[\(Int($0.minX * k)),\(Int($0.minY * k)),\(Int($0.maxX * k)),\(Int($0.maxY * k))]" }.joined(separator: ",")
    // desktop widgets reach the themes under one name, whatever this Mac's language calls Notification Center
    // (themes look for "Notification Centre"; on US-English and other Macs the owner is spelt differently)
    let named = owners.enumerated().map { i, o in i < rects.count && Tracker.widgetRects.contains("\(rects[i])") ? "Notification Centre" : o }
    let names = String(data: try! JSONSerialization.data(withJSONObject: named), encoding: .utf8)!
    let sm = rects.map { Tracker.stageRects.contains("\($0)") ? "1" : "0" }.joined(separator: ",")
    let wins = "{\"t\":\"windows\",\"live\":\(live),\"r\":[\(raw)],\"n\":\(names),\"sm\":[\(sm)]}"
    if wins != lastWins { lastWins = wins; send(wins, live: live) }
    if icons != lastIcons {
      lastIcons = icons
      send("{\"t\":\"icons\",\"vis\":true,\"r\":[\(icons)]}", live: live)
    }
    let mask = Cfg.mask ? local.filter { $0.width > 120 && $0.height > 120 }.map { r -> String in
      let q = r.insetBy(dx: 14, dy: 14)          // rounded corners + shadow edge stay drawn
      return "[\(Int(q.minX)),\(Int(q.minY)),\(Int(q.maxX)),\(Int(q.maxY))]"
    }.joined(separator: ",") : ""
    if mask != lastMask {
      lastMask = mask
      web.evaluateJavaScript("window.__setMask&&window.__setMask([\(mask)]);null", completionHandler: nil)
    }
  }
}

final class WeakHandler: NSObject, WKScriptMessageHandler {
  weak var target: WKScriptMessageHandler?
  init(_ t: WKScriptMessageHandler) { target = t }
  func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(u, didReceive: m) }
}

extension NSScreen {
  var displayID: CGDirectDisplayID { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0 }   // (missing for a moment while displays reconfigure)
  var cgFrame: CGRect { let h = NSScreen.screens.first?.frame.height ?? frame.maxY; return CGRect(x: frame.minX, y: h - frame.maxY, width: frame.width, height: frame.height) }
}

// MARK: - Window tracking (no permissions needed)

struct Snapshot: Equatable { var rects: [CGRect] }

/// Test hook (env TIDEWALL_SIM=1): tools/mover broadcasts a fake cursor riding its title bar + "button held".
final class SimInput {
  static let on = ProcessInfo.processInfo.environment["TIDEWALL_SIM"] == "1"
  static var point: NSPoint?, pressed = false
  static func start() {
    guard on else { return }
    DistributedNotificationCenter.default().addObserver(forName: .init("tidewall.sim"), object: nil, queue: .main) { n in
      let u = n.userInfo ?? [:]; point = NSPoint(x: u["x"] as? Double ?? 0, y: u["y"] as? Double ?? 0); pressed = (u["down"] as? Bool) ?? false
    }
  }
}

final class Tracker {
  var onUpdate: (_ rects: [CGRect], _ live: Bool) -> Void = { _, _ in }
  private(set) var owners: [String] = []
  var onCursor: (CGPoint) -> Void = { _ in }
  private var lastCursor = CGPoint(x: -1, y: -1), lastCursorT = 0.0
  private var timer: Timer?
  private var last: [CGRect] = []
  private var lastPoll = 0.0, burstUntil = 0.0
  private let me = ProcessInfo.processInfo.processIdentifier
  private(set) var polls = 0, pollMs = 0.0

  static let idleInterval = 0.25         // nothing moving under your hand: a look 4× a second (moves you make wake the fast path at once)
  static var allHidden = false      // every screen covered (e.g. a full-screen app): poll at 2 Hz

  private var fastTimer = false, mouseMonitor: Any?
  private func schedule(fast: Bool) {
    if timer != nil && fast == fastTimer { return }
    timer?.invalidate(); fastTimer = fast
    let t = Timer(timeInterval: fast ? 1.0 / 120 : (Self.allHidden ? 0.5 : Self.idleInterval), repeats: true) { [weak self] _ in self?.tick() }
    t.tolerance = fast ? 0.002 : 0.03
    RunLoop.main.add(t, forMode: .common); timer = t
  }
  func start() {
    schedule(fast: false)
    // mouse events need no permission; they wake the fast path the moment you move or grab something
    mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] _ in
      guard let self, !Self.idle else { return }; self.mouseUntil = self.now() + 0.4; self.schedule(fast: true)
    }
    let nc = NSWorkspace.shared.notificationCenter
    for n in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
              NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
              NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
      nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.burst(1.2) }
    }
  }
  func burst(_ s: Double) { burstUntil = max(burstUntil, now() + s); lastPoll = 0; schedule(fast: true) }
  func forceResend() { last = [CGRect(x: -1, y: -1, width: 0, height: 0)]; lastPoll = 0 }
  private func now() -> Double { ProcessInfo.processInfo.systemUptime }

  private func tick() {
    let t = now()
    if t - lastCursorT >= 1.0 / 60 {            // cursor at 60 Hz: the pages draw at most 60 fps while you work, so more is only overhead
      let m = SimInput.point ?? NSEvent.mouseLocation
      if m != lastCursor { lastCursor = m; lastCursorT = t; if let h = NSScreen.screens.first?.frame.height { onCursor(CGPoint(x: m.x, y: h - m.y)) } }
    }
    let dragging = NSEvent.pressedMouseButtons & 1 != 0 || SimInput.pressed
    let fast = dragging || t < burstUntil
    if !fast && t > mouseUntil && fastTimer { schedule(fast: false) }
    if fast && activity == nil {
      activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "tracking moving windows")
    } else if !fast, let a = activity, t - lastFastT > 2 { ProcessInfo.processInfo.endActivity(a); activity = nil }
    if fast { lastFastT = t }
    // fast: every tick (60 Hz) — the page itself paces to its own fps; idle: 2 Hz
    guard fast || t - lastPoll >= (Self.idle ? 2 : Self.allHidden ? 0.5 : Self.idleInterval) else { return }   // nobody's at the Mac: a look every 2 s is plenty
    if fast && lastPoll > 0 { maxGap = max(maxGap, t - lastPoll) }
    lastPoll = t
    let t0 = DispatchTime.now().uptimeNanoseconds
    let found = Self.read(excluding: me)
    let rects = found.map { $0.0 }
    pollMs += Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6; polls += 1
    if rects == last { if wasDragging && !dragging { onUpdate(rects, false) }; wasDragging = dragging; return }
    wasDragging = dragging
    last = rects; owners = found.map { $0.1 }
    if !dragging { burst(0.6) }               // things animate (Stage Manager, minimise) → keep watching
    onUpdate(rects, dragging)          // "live" = your hand is on a window; automatic changes always glide
    updates += 1
    if t - statT >= 1 { if updates > 0 { log(String(format: "HOST polls/s=%.0f updates=%d maxGap=%dms", Double(polls - statPolls) / (t - statT), updates, Int(maxGap * 1000))) }; statT = t; statPolls = polls; updates = 0; maxGap = 0 }
  }
  private var updates = 0, statT = 0.0, statPolls = 0, maxGap = 0.0
  private var activity: NSObjectProtocol?, lastFastT = 0.0, mouseUntil = 0.0, wasDragging = false
  static var idle = false                      // paused by the user, asleep or locked: nothing needs tracking

  static var stageRects = Set<String>()        // Stage Manager thumbnails / badges seen in the last read (drawn tilted by macOS)
  static var widgetRects = Set<String>()       // desktop widgets seen in the last read
  private static var widgetPid: [pid_t: Bool] = [:]
  static func isWidgetOwner(_ pid: pid_t) -> Bool {
    if let v = widgetPid[pid] { return v }
    let v = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.notificationcenterui"; widgetPid[pid] = v; return v
  }
  static func read(excluding me: pid_t) -> [(CGRect, String)] {
    stageRects.removeAll(); widgetRects.removeAll()
    // read straight from the CF list, a field at a time (bridging the whole list into Swift dictionaries cost more than
    // the list itself, several times a second); system windows on other layers are dropped before anything else is read
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) else { return [] }
    func get(_ d: CFDictionary, _ k: CFString) -> AnyObject? {
      CFDictionaryGetValue(d, Unmanaged.passUnretained(k).toOpaque()).map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() } }
    var out: [(CGRect, String)] = []
    for i in 0..<CFArrayGetCount(list) {
      let w = unsafeBitCast(CFArrayGetValueAtIndex(list, i), to: CFDictionary.self)
      guard let layer = (get(w, kCGWindowLayer) as? NSNumber)?.intValue, layer <= 0,
            let pid = (get(w, kCGWindowOwnerPID) as? NSNumber)?.int32Value, pid != me,
            let b = get(w, kCGWindowBounds), CFGetTypeID(b) == CFDictionaryGetTypeID(),
            let r = CGRect(dictionaryRepresentation: unsafeBitCast(b, to: CFDictionary.self)), r.width >= 40, r.height >= 40 else { continue }
      let owner = get(w, kCGWindowOwnerName) as? String ?? ""
      let alpha = (get(w, kCGWindowAlpha) as? NSNumber)?.doubleValue ?? 1
      // normal windows + Stage Manager strip (layer 0); desktop widgets live on a desktop-ish layer
      let widget = layer < 0 && (isWidgetOwner(pid) || owner == "Notification Centre" || owner == "Notification Center")
      guard (layer == 0 || widget), alpha > 0.05, r.width >= 40, r.height >= 40 else { continue }
      // Stage Manager thumbnails + their app proxies share a rect: keep one, named after the app
      if let i = out.firstIndex(where: { $0.0 == r }) { if out[i].1 == "WindowManager" { out[i].1 = owner }; stageRects.insert("\(r)") } else { out.append((r, owner)) }
      if owner == "WindowManager" { stageRects.insert("\(r)") }
      if widget { widgetRects.insert("\(r)") }
    }
    return out
  }
}

/// Exact uncovered area (pt²) of a screen: union of window rects via coordinate compression. A handful of
/// rects → microseconds, and a 2 pt sliver between windows counts as visible (no sampling to miss it).
func uncoveredArea(_ screen: CGRect, _ rects: [CGRect]) -> Double {
  let rs = rects.map { $0.intersection(screen) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
  if rs.isEmpty { return Double(screen.width * screen.height) }
  let xs = Array(Set(rs.flatMap { [$0.minX, $0.maxX] } + [screen.minX, screen.maxX])).sorted()
  let ys = Array(Set(rs.flatMap { [$0.minY, $0.maxY] } + [screen.minY, screen.maxY])).sorted()
  var free = 0.0
  for i in 0..<(xs.count - 1) { for j in 0..<(ys.count - 1) {
    let c = CGPoint(x: (xs[i] + xs[i + 1]) / 2, y: (ys[j] + ys[j + 1]) / 2)
    if !rs.contains(where: { $0.contains(c) }) { free += Double((xs[i + 1] - xs[i]) * (ys[j + 1] - ys[j])) }
  } }
  return free
}

// MARK: - Usage meter (Tidewall + every helper process macOS bills to it: WebKit page, GPU, network)

// MARK: - Desktop icons (opt-in): where Finder shows them, so each theme can keep them clear

/// Finder knows where every desktop icon is; it tells us through one Apple event (macOS asks the user once). Read
/// every few seconds and just after a drag, off the main thread, with a timeout. Each icon becomes a box (its image
/// and the label under it, sized from Finder's own desktop view settings) in global CG points; neighbouring icons are
/// grouped into clusters, so a column of icons is one tall shape rather than twenty specks.
final class DeskIcons {
  enum State: String { case off, ok, denied, failed }
  static weak var shared: DeskIcons?
  private(set) var icons: [CGRect] = [], clusters: [CGRect] = [], images: [CGRect] = []   // whole icons (image + label), groups of them, the images alone
  private(set) var state = State.off, known = false                    // known: icons read since launch (else the last launch's)
  var onChange: () -> Void = {}
  private var script: NSAppleScript?, timer: Timer?, monitor: Any?, busy = false, lastClick = 0.0
  /// true while the wallpaper rests (paused, idle, asleep, let go, paused on battery): no need to ask Finder then
  var resting: () -> Bool = { false }
  /// NSAppleScript (an OSA component) isn't thread-safe: it's made and run on this one thread, always the same
  private static let worker: CFRunLoop = {
    var loop: CFRunLoop?; let ready = DispatchSemaphore(value: 0)
    let t = Thread { loop = CFRunLoopGetCurrent(); RunLoop.current.add(NSMachPort(), forMode: .default); ready.signal(); while true { RunLoop.current.run(mode: .default, before: .distantFuture) } }
    t.name = "tidewall.desk-icons"; t.qualityOfService = .utility; t.start(); ready.wait(); return loop!
  }()
  private func onWorker(_ f: @escaping () -> Void) { let rl = Self.worker; CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue, f); CFRunLoopWakeUp(rl) }
  var fake: [(CGRect, CGRect)]? = nil                                   // dev: --fakeicons (box, image)

  func start() {
    stop()
    guard Cfg.deskIcons || fake != nil else { state = .off; set([]); return }
    if let fake { state = .ok; set(fake.map(\.0), fake.map(\.1)); return }
    timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.read() }
    read()
    timer?.tolerance = 0.5
    // an icon dragged to a new spot: look again as soon as it's dropped
    monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
      guard let self, ProcessInfo.processInfo.systemUptime - self.lastClick > 1 else { return }   // at most once a second
      self.lastClick = ProcessInfo.processInfo.systemUptime
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.read() } }
  }
  func stop() { timer?.invalidate(); timer = nil; if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil }

  /// Finder's desktop view: icon size, label size and where the label goes
  static func geometry() -> (icon: CGFloat, text: CGFloat, bottom: Bool) {
    CFPreferencesAppSynchronize("com.apple.finder" as CFString)
    let v = CFPreferencesCopyAppValue("DesktopViewSettings" as CFString, "com.apple.finder" as CFString) as? [String: Any]
    let s = v?["IconViewSettings"] as? [String: Any]
    let icon = (s?["iconSize"] as? NSNumber)?.doubleValue ?? 64, text = (s?["textSize"] as? NSNumber)?.doubleValue ?? 12
    let bottom = (s?["labelOnBottom"] as? NSNumber)?.boolValue ?? true
    return (CGFloat(min(512, max(16, icon))), CGFloat(min(24, max(9, text))), bottom)
  }
  /// an icon's box from the centre of its image (what Finder reports): the image and, below or beside it, a label of
  /// up to two lines
  static func box(_ c: CGPoint, _ g: (icon: CGFloat, text: CGFloat, bottom: Bool)) -> CGRect {
    let img = CGRect(x: c.x - g.icon / 2, y: c.y - g.icon / 2, width: g.icon, height: g.icon)
    let lh = g.text * 1.3 * 2 + 4
    let label = g.bottom ? CGRect(x: c.x - max(g.icon + 20, g.text * 7) / 2, y: img.maxY + 2, width: max(g.icon + 20, g.text * 7), height: lh)
                         : CGRect(x: img.maxX + 4, y: c.y - lh / 2, width: g.text * 10, height: lh)
    return img.union(label)
  }
  static func cluster(_ rs: [CGRect], gap: CGFloat = 26) -> [CGRect] {
    var out = rs
    var merged = true
    while merged { merged = false
      outer: for i in 0..<out.count { for j in (i + 1)..<max(i + 1, out.count) where out[i].insetBy(dx: -gap / 2, dy: -gap / 2).intersects(out[j].insetBy(dx: -gap / 2, dy: -gap / 2)) {
        out[i] = out[i].union(out[j]); out.remove(at: j); merged = true; break outer } } }
    return out
  }
  /// icons on the desktop that macOS isn't showing (Finder's desktop switched off, or "Show items" off in Desktop & Dock,
  /// on the desktop or in Stage Manager): Finder still knows where they are, but there's nothing to make room for
  static func hidden() -> Bool {
    let f = "com.apple.finder" as CFString, wm = "com.apple.WindowManager" as CFString
    CFPreferencesAppSynchronize(f); CFPreferencesAppSynchronize(wm)
    if (CFPreferencesCopyAppValue("CreateDesktop" as CFString, f) as? Bool) == false { return true }
    let stage = (CFPreferencesCopyAppValue("GloballyEnabled" as CFString, wm) as? Bool) ?? false
    return (CFPreferencesCopyAppValue((stage ? "HideDesktop" : "StandardHideDesktopIcons") as CFString, wm) as? Bool) ?? false
  }
  private func set(_ rs: [CGRect], _ ims: [CGRect] = []) {
    known = true; if Cfg.d.bool(forKey: "iconsPresent") != !rs.isEmpty { Cfg.d.set(!rs.isEmpty, forKey: "iconsPresent") }   // (a launch opens the tunnel on the right model)
    if rs == icons && ims == images { return }                           // (before clustering: that's the costly part)
    let cl = Self.cluster(rs)
    icons = rs; clusters = cl; images = ims; onChange()
  }
  /// the image part of an icon's box (what the snow settles on, say)
  static func image(_ c: CGPoint, _ g: (icon: CGFloat, text: CGFloat, bottom: Bool)) -> CGRect { CGRect(x: c.x - g.icon / 2, y: c.y - g.icon / 2, width: g.icon, height: g.icon) }
  func read() {
    guard !busy, Cfg.deskIcons, timer != nil, !resting() else { return }
    if Self.hidden() { if state != .ok { state = .ok; onChange() }; set([]); return }
    busy = true
    let g = Self.geometry()
    onWorker { [weak self] in
      guard let self else { return }
      if self.script == nil {                                           // made and run on this one thread only
        self.script = NSAppleScript(source: "with timeout of 3 seconds\ntell application \"Finder\" to get desktop position of every item of desktop\nend timeout") }
      var err: NSDictionary?
      let d = self.script?.executeAndReturnError(&err)
      var pts: [CGPoint] = []
      if err == nil, let d, d.numberOfItems > 0 {
        for i in 1...d.numberOfItems { if let p = d.atIndex(i), p.numberOfItems >= 2, let x = p.atIndex(1)?.int32Value, let y = p.atIndex(2)?.int32Value {
          pts.append(CGPoint(x: CGFloat(x), y: CGFloat(y))) } } }
      let code = (err?[NSAppleScript.errorNumber] as? NSNumber)?.intValue
      DispatchQueue.main.async {
        self.busy = false
        guard Cfg.deskIcons else { return }
        let before = self.state; defer { if self.state != before { self.onChange() } }
        switch code {
        case nil: self.state = .ok; self.set(pts.map { Self.box($0, g) }, pts.map { Self.image($0, g) })
        case -1743, -1744: if self.state != .denied { log("[icons] not allowed to ask Finder (System Settings ▸ Privacy & Security ▸ Automation)") }; self.state = .denied; self.set([])
        case -600: self.state = .ok; self.set([])                       // Finder isn't running: no desktop icons
        default: if self.state != .failed { log("[icons] couldn't read them (\(code!))") }; self.state = .failed
        }
      }
    }
  }
}

final class Usage {
  typealias RespFn = @convention(c) (pid_t) -> pid_t
  private static let responsible: RespFn? = {
    guard let h = dlopen(nil, RTLD_NOW), let s = dlsym(h, "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(s, to: RespFn.self)
  }()
  private let me = ProcessInfo.processInfo.processIdentifier
  private var lastCPU: [pid_t: UInt64] = [:], lastGPU: UInt64 = 0, lastT = 0.0
  private let tb: Double = { var i = mach_timebase_info_data_t(); mach_timebase_info(&i); return Double(i.numer) / Double(i.denom) }()
  struct Sample { var cpu = 0.0, gpu = 0.0, memMB = 0.0, procs = 0, cpuBy: [pid_t: Double] = [:], memBy: [pid_t: Double] = [:] }

  func family() -> [pid_t] {
    var pids = [me]
    guard let resp = Self.responsible else { return pids }
    let n = proc_listallpids(nil, 0); var buf = [pid_t](repeating: 0, count: Int(n) + 64)
    let c = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.size)); guard c > 0 else { return pids }
    for p in buf.prefix(Int(c)) where p > 0 && p != me && resp(p) == me { pids.append(p) }
    return pids
  }
  private func rusage(_ pid: pid_t) -> rusage_info_v4? {
    var ri = rusage_info_v4()
    let r = withUnsafeMutablePointer(to: &ri) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
    return r == 0 ? ri : nil
  }
  /// GPU busy time (ns) the driver has billed to our pids (WebKit's GPU work is billed to the app). The per-process
  /// counters live on the GPU driver's user clients, which are children of the accelerator: walk just those. (Walking
  /// the whole I/O registry to find them cost ~25 ms of main thread per reading.)
  private func gpuNs(_ pids: Set<pid_t>) -> UInt64 {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return 0 }
    defer { IOObjectRelease(it) }
    var total: UInt64 = 0
    while case let acc = IOIteratorNext(it), acc != 0 {
      defer { IOObjectRelease(acc) }
      var ch: io_iterator_t = 0
      guard IORegistryEntryGetChildIterator(acc, kIOServicePlane, &ch) == KERN_SUCCESS else { continue }
      defer { IOObjectRelease(ch) }
      while case let e = IOIteratorNext(ch), e != 0 {
        defer { IOObjectRelease(e) }
        guard let creator = IORegistryEntryCreateCFProperty(e, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
              let pidStr = creator.split(separator: ",").first?.split(separator: " ").last, let pid = pid_t(pidStr), pids.contains(pid),
              let usage = IORegistryEntryCreateCFProperty(e, "AppUsage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]] else { continue }
        for u in usage { total += (u["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0 }
      }
    }
    return total
  }
  func sample() -> Sample {
    let t = ProcessInfo.processInfo.systemUptime, pids = family()
    var s = Sample(); s.procs = pids.count
    var cpuNow: [pid_t: UInt64] = [:], dCPU: UInt64 = 0
    for p in pids { guard let r = rusage(p) else { continue }
      let c = r.ri_user_time + r.ri_system_time; cpuNow[p] = c
      if let l = lastCPU[p], c >= l { dCPU += c - l; if t > lastT, lastT > 0 { s.cpuBy[p] = Double(c - l) * tb / 1e9 / (t - lastT) * 100 } }
      let mb = Double(r.ri_phys_footprint) / 1_048_576; s.memMB += mb; s.memBy[p] = mb }
    let g = gpuNs(Set(pids)), dt = t - lastT
    if lastT > 0, dt > 0 { s.cpu = Double(dCPU) * tb / 1e9 / dt * 100; s.gpu = Double(g >= lastGPU ? g - lastGPU : 0) / 1e9 / dt * 100 }
    lastCPU = cpuNow; lastGPU = g; lastT = t
    return s
  }
}

// MARK: - Start at login (a per-user LaunchAgent: starts at login, restarts after a crash, stays quit when you quit)

enum LoginItem {
  static let label = "app.tidewall"
  static var oldPlist: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/local.driftland.plist") }
  static var plist: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
  static var enabled: Bool { FileManager.default.fileExists(atPath: plist.path) }
  /// on, but switched off for Tidewall in System Settings ▸ General ▸ Login Items
  static var blocked: Bool { enabled && SMAppService.statusForLegacyPlist(at: plist) == .requiresApproval }
  /// the app was moved (say into /Applications) since the login item was made: point it at where the app is now
  static func refresh() {
    guard enabled, Bundle.main.bundleIdentifier != nil, let d = NSDictionary(contentsOf: plist), let a = d["ProgramArguments"] as? [String],
          let first = a.first, first != URL(fileURLWithPath: CommandLine.arguments[0]).standardized.resolvingSymlinksInPath().path else { return }
    set(true); log("login item: now opens \(CommandLine.arguments[0])")
  }
  /// returns why it couldn't, if it couldn't
  @discardableResult static func set(_ on: Bool) -> String? {
    try? FileManager.default.removeItem(at: oldPlist)                    // the agent from before the rename
    if !on { try? FileManager.default.removeItem(at: plist); return nil } // takes effect from the next login
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardized.resolvingSymlinksInPath().path
    // opened straight from Downloads, macOS runs the app from a temporary copy that is gone by the next login
    if exe.contains("/AppTranslocation/") { return "Move Tidewall to your Applications folder first, then turn this on." }
    let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Tidewall.log").path
    let dict: [String: Any] = [
      "Label": label, "ProgramArguments": argValue("--themes") != nil ? [exe, "--background", "--themes", themesRoot.path] : [exe, "--background"], "RunAtLoad": true,
      "KeepAlive": ["SuccessfulExit": false], "ProcessType": "Interactive", "StandardOutPath": log, "StandardErrorPath": log,
    ]
    do {
      try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
      try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: plist)
    } catch { return "Couldn't set up opening at login: \(error.localizedDescription)" }
    return nil
  }
}


// MARK: - The app window: themes with a live preview, displays, settings (an HTML page in a native, translucent window)

/// Runs in every frame of the app window. The preview frame (a real theme page) gets the host surface it expects, but
/// its messages go to the page around it, which plays host: a pretend desktop with windows you can drag.
let frameShim = """
(() => {
  if (window.top === window) return;
  // the preview is shown small: render at the pixels it's shown at, not at the full desktop's retina size
  const pd = parseFloat(new URLSearchParams(location.search).get('pdpr'));
  if (pd > 0) try { Object.defineProperty(window, 'devicePixelRatio', { get: () => pd, configurable: true }); } catch (_) {}
  const ls = [];
  window.chrome = window.chrome || {};
  window.chrome.webview = { postMessage: m => parent.postMessage({ __twFrom: typeof m === 'string' ? m : JSON.stringify(m) }, '*'),
    addEventListener: (t, f) => { if (t === 'message') ls.push(f); }, removeEventListener: () => {} };
  addEventListener('message', e => { if (e.source === parent && e.data && e.data.__tw !== undefined) for (const f of ls) f({ data: e.data.__tw }); });
  window.__opaque = true;
  // each WebGL context remembered on its canvas, so the window can let go of it the moment this preview is replaced
  const gc = HTMLCanvasElement.prototype.getContext;
  HTMLCanvasElement.prototype.getContext = function (type, ...a) { const c = gc.call(this, type, ...a); if (c && String(type).indexOf('webgl') === 0) this.__twGL = c; return c; };
})();
"""

final class AppWindow: NSObject, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
  func webViewWebContentProcessDidTerminate(_ w: WKWebView) { log("[ui] web process ended; reloading"); w.load(URLRequest(url: URL(string: "tidewall://app/ui/index.html")!)) }
  weak var app: App?
  var window: NSWindow?, web: WKWebView?, usageTimer: Timer?
  init(app: App) { self.app = app }

  private var pendingPage: String?
  func show(page: String? = nil) {
    NSApp.setActivationPolicy(.regular)
    let fresh = window == nil
    if fresh { build() }
    window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    if let page { if fresh { pendingPage = page } else { js("{\"t\":\"show\",\"page\":\"\(page)\"}") } }   // a new window: once it says hello
  }
  private func build() {
    let cfg = WKWebViewConfiguration()           // its own web process: the preview can never stall the wallpapers, and it ends with the window
    cfg.setURLSchemeHandler(SchemeHandler(), forURLScheme: "tidewall")
    let ucc = cfg.userContentController
    ucc.addUserScript(WKUserScript(source: frameShim, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    ucc.add(WeakHandler(self), name: "ui"); ucc.add(WeakHandler(self), name: "host")
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    w.title = "Tidewall"; w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
    w.toolbar = NSToolbar(identifier: "tidewall"); w.toolbarStyle = .unified
    w.minSize = NSSize(width: 960, height: 640); w.isReleasedWhenClosed = false; w.delegate = self
    w.center(); w.setFrameAutosaveName("TidewallWindow")
    let vfx = NSVisualEffectView(); vfx.material = .sidebar; vfx.blendingMode = .behindWindow; vfx.state = .followsWindowActiveState
    w.contentView = vfx
    let wv = WKWebView(frame: vfx.bounds, configuration: cfg); wv.autoresizingMask = [.width, .height]; wv.navigationDelegate = self
    wv.setValue(false, forKey: "drawsBackground")
    vfx.addSubview(wv)
    // the page fills the window, title-bar strip included, and WebKit ignores -webkit-app-region (an Electron-only
    // feature): without these strips the window can't be dragged. Top 28 pt across, and the sidebar's empty top.
    for (x, w0, h) in [(0.0, vfx.bounds.width, 28.0), (0.0, 222.0, 52.0)] {
      let d = TitlebarDrag(frame: NSRect(x: x, y: vfx.bounds.height - h, width: w0, height: h))
      d.autoresizingMask = w0 == 222 ? [.minYMargin] : [.width, .minYMargin]; vfx.addSubview(d)
    }
    wv.load(URLRequest(url: URL(string: "tidewall://app/ui/index.html")!))
    window = w; web = wv
    _ = app?.usage.sample()
    usageTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      guard let w = self?.window, w.occlusionState.contains(.visible), !w.isMiniaturized else { return }   // hidden or minimised: nobody's reading them
      self?.pushUsage() }
  }
  func windowWillClose(_ n: Notification) {
    usageTimer?.invalidate(); usageTimer = nil
    DispatchQueue.main.async { [weak self] in              // the page, its live preview and all their memory go with the window
      guard let self else { return }
      self.web?.configuration.userContentController.removeAllScriptMessageHandlers()
      self.web?.removeFromSuperview(); self.web = nil; self.window = nil
      NSApp.setActivationPolicy(.accessory)
      if args.contains("--ui-only") && !args.contains("--closetest") { NSApp.terminate(nil) }
    }
  }
  func pushDesktop(icons: Bool = false) { guard web != nil else { return }; js("{\"t\":\"desktop\",\"d\":\(desktopJSON())\(icons ? ",\"icons\":1" : "")}") }
  func toast(_ s: String) { if let d = try? JSONSerialization.data(withJSONObject: ["t": "toast", "s": s]), let j = String(data: d, encoding: .utf8) { js(j) } }
  func js(_ json: String) { web?.evaluateJavaScript("window.tw&&tw.receive(\(json));null", completionHandler: nil) }
  /// what the wallpaper costs, and (apart) what this window costs while it's open
  func pushUsage() {
    guard let u = app?.usage.sample() else { return }
    let ui = pid_t(web.map(webPid) ?? -1), uc = u.cpuBy[ui] ?? 0, um = u.memBy[ui] ?? 0
    js(String(format: "{\"t\":\"usage\",\"cpu\":%.2f,\"gpu\":%.2f,\"mem\":%.1f,\"winCpu\":%.2f,\"winMem\":%.1f}", max(0, u.cpu - uc), u.gpu, max(0, u.memMB - um), uc, um))
  }
  /// the main display and what's on it now: the preview shows your own desktop
  func desktopJSON(display: CGDirectDisplayID? = nil) -> String {
    guard let app, let scr = NSScreen.screens.first(where: { $0.displayID == display }) ?? NSScreen.screens.first else { return "null" }
    let fake = display.flatMap { fakeWorld[$0] }                       // dev: a pretend display
    let f = fake ?? scr.cgFrame
    var wins: [[String: Any]] = []
    for (i, r) in app.lastRects.enumerated() where r.intersects(f) {
      let owner = i < app.lastOwners.count ? app.lastOwners[i] : ""
      if ["Tidewall", "tidewall", "WindowManager", "Dock"].contains(owner) { continue }   // this window; Stage Manager's app-icon badges
      wins.append(["x": r.minX - f.minX, "y": r.minY - f.minY, "w": r.width, "h": r.height, "name": owner,
                   "sm": Tracker.stageRects.contains("\(r)"), "widget": Tracker.widgetRects.contains("\(r)") || owner == "Notification Centre" || owner == "Notification Center" || owner == "WidgetKit Simulator"])
    }
    // your desktop icons on this display (image + label, the image alone, and the groups), so the preview shows what each theme does with them
    let di = DeskIcons.shared, loc = { (r: CGRect) -> [CGFloat] in [r.minX - f.minX, r.minY - f.minY, r.width, r.height] }
    let on = (di?.icons ?? []).indices.filter { di!.icons[$0].intersects(f) }
    let icons: [String: Any] = ["r": on.map { loc(di!.icons[$0]) }, "i": on.compactMap { $0 < di!.images.count ? loc(di!.images[$0]) : nil },
                                "c": (di?.clusters ?? []).filter { $0.intersects(f) }.map(loc)]
    let d: [String: Any] = ["w": f.width, "h": f.height, "windows": wins, "icons": icons, "display": Int(fake != nil ? display! : scr.displayID),
                            "notch": fake.map { $0.origin == .zero && scr.safeAreaInsets.top > 0 } ?? (scr.safeAreaInsets.top > 0)]
    return (try? JSONSerialization.data(withJSONObject: d)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
  }
  func pushState() {
    guard let app, web != nil else { return }
    if !fakeWorld.isEmpty {                                          // dev: the harness's pretend displays, as the window would list real ones
      let ids = fakeWorld.keys.sorted(), main = ids.first { fakeWorld[$0]?.origin == .zero }
      let ds = ids.map { id -> [String: Any] in let f = fakeWorld[id]!, t = Cfg.theme(for: id)
        let world = Cfg.spanWorlds && Cfg.spanThemes.contains(t) ? ids.filter { Cfg.theme(for: $0) == t }.map { Int($0) } : [Int(id)]
        return ["id": Int(id), "name": id == main ? "Built-in Retina Display" : "Monitor \(id - 1000)", "x": f.minX, "y": f.minY, "w": f.width, "h": f.height, "theme": t,
                "own": Cfg.d.string(forKey: "theme.display.\(id)") != nil, "main": id == main, "world": world] }
      return pushStateWith(ds)
    }
    let ds = NSScreen.screens.map { s -> [String: Any] in let f = s.cgFrame, id = s.displayID
      return ["id": Int(id), "name": s.localizedName, "x": f.minX, "y": f.minY, "w": f.width, "h": f.height, "theme": Cfg.theme(for: id),
              "own": Cfg.d.string(forKey: "theme.display.\(id)") != nil, "main": s == NSScreen.screens.first,
              "world": Cfg.world(of: id).map { Int($0.displayID) }] }
    pushStateWith(ds)
  }
  private func pushStateWith(_ ds: [[String: Any]]) {
    guard let app else { return }
    var vars: [String: String] = [:]; for (t, _) in Cfg.themes { if let v = Cfg.variant(t) { vars[t] = v } }
    let st: [String: Any] = ["t": "state", "current": Cfg.theme, "displays": ds, "variants": vars, "seed": Cfg.seed, "version": Cfg.version, "siteQuery": Cfg.siteQuery,
      "spanThemes": Array(Cfg.spanThemes), "settings": ["spanWorlds": Cfg.spanWorlds, "login": LoginItem.enabled, "loginBlocked": LoginItem.blocked, "restWhenIdle": Cfg.restWhenIdle, "paused": app.userPaused, "fps": Cfg.fps, "margin": Cfg.margin, "autoUpdate": Cfg.autoUpdate, "deskIcons": Cfg.deskIcons, "deskIconsState": app.deskIcons.state.rawValue,
                     "reactWindows": Cfg.reactWindows, "reactStage": Cfg.reactStage, "reactWidgets": Cfg.reactWidgets, "reactCursor": Cfg.reactCursor,
                     "idleMinutes": Cfg.idleMinutes, "battery": Cfg.battery, "onBattery": app.onBattery, "lowPower": app.lowPower],
      "update": app.updater.status, "newNotes": Cfg.hasNewNotes, "notesSeen": Cfg.notesSeen ?? ""]
    if let d = try? JSONSerialization.data(withJSONObject: st), let s = String(data: d, encoding: .utf8) { js(s) }
  }
  func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
    if m.name == "host" { let s = "\(m.body)"; if s.hasPrefix("JSERR") { log("[preview] \(s)") }; return }
    guard m.frameInfo.isMainFrame, let app, let str = m.body as? String, let d = str.data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let t = o["t"] as? String else { return }
    switch t {
    case "hello":
      pushState(); pushUsage(); js("{\"t\":\"desktop\",\"d\":\(desktopJSON())}")
      if let d = try? JSONSerialization.data(withJSONObject: ["t": "notes", "md": Cfg.changelog]), let j = String(data: d, encoding: .utf8) { js(j) }
      if let p = pendingPage { pendingPage = nil; js("{\"t\":\"show\",\"page\":\"\(p)\"}") }
      return
    case "notesSeen": Cfg.notesSeen = Cfg.version; app.buildMenu()
    case "desktop": js("{\"t\":\"desktop\",\"d\":\(desktopJSON(display: (o["display"] as? Int).flatMap { CGDirectDisplayID(exactly: $0) }))}"); return
    case "openAutomation": NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!); return
    case "open": if let s = o["url"] as? String, let url = URL(string: s), ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }; return
    case "log": log("[ui] \(o["s"] as? String ?? "")"); return
    case "apply": if let id = o["theme"] as? String, Cfg.themes.contains(where: { $0.0 == id }) { Cfg.clearDisplayThemes(); Cfg.theme = id; app.reloadAll() }
    case "applyDisplay":
      let th = o["theme"] as? String
      if let did = o["display"] as? Int, let id = CGDirectDisplayID(exactly: did), NSScreen.screens.contains(where: { $0.displayID == id }) || fakeWorld[id] != nil,
         th == nil || Cfg.themes.contains(where: { $0.0 == th }) { Cfg.setTheme(th, for: id); app.reloadWall(id); app.resendDesks() }
      else { toast("That display isn't connected any more.") }
    case "variant": if let th = o["theme"] as? String, let v = o["id"] as? String {
        Cfg.setVariant(th, v); for s in NSScreen.screens where Cfg.theme(for: s.displayID) == th { app.reloadWall(s.displayID) } }
    case "set":
      let v = o["value"]
      switch o["key"] as? String ?? "" {
      case "login":
        if args.contains("--ui-only") { toast("Development window: the login item isn't changed."); break }
        if LoginItem.blocked && (v as? Bool ?? false) { SMAppService.openSystemSettingsLoginItems(); break }
        if let why = LoginItem.set(v as? Bool ?? false) { toast(why) }
      case "restWhenIdle": Cfg.idleMinutes = (v as? Bool ?? true) ? Cfg.idleLast : 0
      case "spanWorlds": Cfg.spanWorlds = v as? Bool ?? true; app.resendDesks(); app.tracker.forceResend()   // each page: its new world's windows
      case "deskIcons": Cfg.deskIcons = v as? Bool ?? false; app.deskIcons.start()   // turning it on is when macOS asks, once
      case "autoUpdate": Cfg.autoUpdate = v as? Bool ?? true; if Cfg.autoUpdate { app.updater.check(manual: false) }
      case "paused": app.userPaused = v as? Bool ?? false; app.dispatch(live: false)
      case "fps": Cfg.fps = (v as? NSNumber)?.doubleValue ?? 0; app.reloadAll()
      case "margin": Cfg.margin = (v as? NSNumber)?.doubleValue ?? 140; app.tracker.forceResend(); app.dispatch(live: false)   // every page, now
      case "reactWindows", "reactStage", "reactWidgets":
        let on = v as? Bool ?? true, k = o["key"] as? String ?? ""
        if k == "reactWindows" { Cfg.reactWindows = on } else if k == "reactStage" { Cfg.reactStage = on } else { Cfg.reactWidgets = on }
        app.tracker.forceResend(); app.dispatch(live: false)
      case "reactCursor": Cfg.reactCursor = v as? Bool ?? true; if !Cfg.reactCursor { for w in app.walls.values { w.send("{\"t\":\"cursorOff\"}") } }
      case "idleMinutes": Cfg.idleMinutes = (v as? NSNumber)?.doubleValue ?? 3
      case "battery": Cfg.battery = (v as? NSNumber)?.intValue ?? 0; app.checkPower()
      default: break }
    case "reload": app.reloadAll()
    case "checkUpdate": app.updater.check(manual: false, fromWindow: true)
    case "installUpdate": app.updater.install()
    case "quit": NSApp.terminate(nil)
    default: break
    }
    pushState(); app.buildMenu()
  }
}

/// A window macOS doesn't shrink to fit the screen (the harness's pretend displays can be bigger than the real one)
final class FreeSizeWindow: NSWindow { override func constrainFrameRect(_ r: NSRect, to s: NSScreen?) -> NSRect { r } }
/// Test harness (--fakescreens): pretend displays, id → frame (CG points), all drawn by pages in this one app
var fakeWorld: [CGDirectDisplayID: CGRect] = [:]
/// … and each one's pixels per point (an ordinary external monitor is 1×: its page then draws at 1×, as on a real one)
var fakeScale: [CGDirectDisplayID: CGFloat] = [:]
/// Every display (frame) in the world this display's page draws: the displays showing the same spanning theme
/// (in one world), or just this one
func worldFrames(for id: CGDirectDisplayID) -> [CGRect] {
  if !fakeWorld.isEmpty {
    let t = Cfg.theme(for: id), spans = Cfg.spanWorlds && Cfg.spanThemes.contains(t)
    return spans ? fakeWorld.keys.sorted().filter { Cfg.theme(for: $0) == t }.compactMap { fakeWorld[$0] } : [fakeWorld[id] ?? .zero]
  }
  return Cfg.world(of: id).map { $0.cgFrame }
}
/// Every display's frame (the whole desk), real or pretend
func allFrames() -> [CGRect] { fakeWorld.isEmpty ? NSScreen.screens.map { $0.cgFrame } : fakeWorld.keys.sorted().compactMap { fakeWorld[$0] } }

/// Display names as people see them, with the size (or position) added when two share a name
func displayNames() -> [CGDirectDisplayID: String] {
  var out: [CGDirectDisplayID: String] = [:]
  for s in NSScreen.screens {
    let same = NSScreen.screens.filter { $0.localizedName == s.localizedName }
    if same.count < 2 { out[s.displayID] = s.localizedName; continue }
    let f = s.frame.size, sameSize = same.filter { $0.frame.size == f }
    out[s.displayID] = sameSize.count < 2 ? "\(s.localizedName) (\(Int(f.width))×\(Int(f.height)))"
      : "\(s.localizedName) (\((sameSize.sorted { $0.frame.minX < $1.frame.minX }.firstIndex(of: s) ?? 0) + 1))"
  }
  return out
}

/// The menu-bar glyph: a window with a tide curling inside it (the app icon's idea, as a template image so it follows the menu bar)
func menuGlyph() -> NSImage {
  let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
    NSColor.black.set()
    let win = NSBezierPath(roundedRect: NSRect(x: 1.6, y: 2.6, width: 14.8, height: 12.8), xRadius: 3.5, yRadius: 3.5); win.lineWidth = 1.5; win.stroke()
    NSGraphicsContext.current?.saveGraphicsState(); win.addClip()
    let p = NSBezierPath(); p.move(to: NSPoint(x: 18, y: 9.6))
    p.curve(to: NSPoint(x: 9.2, y: 11.6), controlPoint1: NSPoint(x: 15.4, y: 12.2), controlPoint2: NSPoint(x: 11.8, y: 12.6))   // the crest
    p.curve(to: NSPoint(x: 6.4, y: 8.4), controlPoint1: NSPoint(x: 7.0, y: 11.0), controlPoint2: NSPoint(x: 5.9, y: 9.6))       // curling over
    p.curve(to: NSPoint(x: 9.0, y: 8.2), controlPoint1: NSPoint(x: 6.9, y: 7.2), controlPoint2: NSPoint(x: 8.6, y: 7.2))       // the inside of the curl
    p.curve(to: NSPoint(x: 7.6, y: 5.6), controlPoint1: NSPoint(x: 9.6, y: 6.9), controlPoint2: NSPoint(x: 9.0, y: 5.8))
    p.curve(to: NSPoint(x: 0, y: 6.2), controlPoint1: NSPoint(x: 5.4, y: 5.3), controlPoint2: NSPoint(x: 2.0, y: 7.4))         // the trough
    p.line(to: NSPoint(x: 0, y: 0)); p.line(to: NSPoint(x: 18, y: 0)); p.close(); p.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    return true
  }
  img.isTemplate = true; return img
}

/// The app's own menu (shown while the window is open and Tidewall is in the Dock)
func buildMainMenu(_ open: @escaping () -> Void) {
  let main = NSMenu(), appItem = NSMenuItem(); main.addItem(appItem)
  let am = NSMenu()
  am.addItem(ClosureItem("About Tidewall") { open() })
  am.addItem(.separator())
  let hide = NSMenuItem(title: "Hide Tidewall", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"); am.addItem(hide)
  am.addItem(.separator())
  am.addItem(NSMenuItem(title: "Quit Tidewall", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
  appItem.submenu = am
  let winItem = NSMenuItem(); main.addItem(winItem)
  let wm = NSMenu(title: "Window")
  wm.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
  wm.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
  winItem.submenu = wm
  NSApp.mainMenu = main
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
  let usage = Usage()
  var usageTimer: Timer?
  func menuWillOpen(_ menu: NSMenu) {
    _ = usage.sample()                                   // baseline, then refresh every 2 s while open
    refreshUsage(menu, first: true)
    let t = Timer(timeInterval: 2, repeats: true) { [weak self, weak menu] _ in if let menu { self?.refreshUsage(menu, first: false) } }
    RunLoop.main.add(t, forMode: .common); usageTimer = t
  }
  func menuDidClose(_ menu: NSMenu) { usageTimer?.invalidate(); usageTimer = nil }
  func refreshUsage(_ menu: NSMenu, first: Bool) {
    let s = first ? Usage.Sample() : usage.sample()
    let mono = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    let ui = pid_t(appWindow.web.map(webPid) ?? -1), wc = s.cpuBy[ui] ?? 0, wm = s.memBy[ui] ?? 0
    let lines = first ? ["CPU     measuring…", "GPU     measuring…", "Memory  measuring…", ""]
      : [String(format: "CPU     %.1f%%", max(0, s.cpu - wc)), String(format: "GPU     %.1f%%", s.gpu) + (wm > 0 ? "  incl. window" : ""), String(format: "Memory  %.0f MB", max(0, s.memMB - wm)),
         wm > 0 ? String(format: "+ window %.0f MB, freed on close", wm) : ""]
    for (i, l) in lines.enumerated() { guard let it = menu.item(withTag: 900 + i) else { continue }
      it.isHidden = l.isEmpty; it.attributedTitle = NSAttributedString(string: l, attributes: [.font: mono]) }
  }
  var walls: [CGDirectDisplayID: Wallpaper] = [:]
  let tracker = Tracker()
  let deskIcons = DeskIcons()
  func sendDeskIcons() { for w in walls.values { w.sendDeskIcons() }; appWindow.pushState(); appWindow.pushDesktop(icons: true) }
  var status: NSStatusItem!
  var userPaused = benchMode ? args.contains("--paused") : Cfg.d.bool(forKey: "paused") { didSet { if !benchMode { Cfg.d.set(userPaused, forKey: "paused") } } }
  var locked = false, displaysAsleep = false, awayTimer: Timer?, releasedAway = false, idleRest = false, idleTimer: Timer?, testPauseArmed = false
  var asleep: Bool { locked || displaysAsleep }
  var lastRects: [CGRect] = []
  var lastOwners: [String] = []
  weak var cursorWall: Wallpaper?
  lazy var appWindow = AppWindow(app: self)
  let updater = Updater()
  func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows f: Bool) -> Bool { if !benchMode { appWindow.show() }; return false }

  func applicationDidFinishLaunching(_ n: Notification) {
    if !benchMode { updater.launching() }
    if let a = argValue("--appearance") { NSApp.appearance = NSAppearance(named: a == "light" ? .aqua : .darkAqua) }
    if args.contains("--ui-only") {           // dev: just the app window (no wallpapers), to work on the interface
      tracker.onUpdate = { [weak self] r, _ in self?.lastRects = r; self?.lastOwners = self?.tracker.owners ?? [] }; tracker.start()
      buildMainMenu { [weak self] in self?.appWindow.show(page: "about") }; appWindow.show()
      if let c = argValue("--closetest"), let t = Double(c) { DispatchQueue.main.asyncAfter(deadline: .now() + t) { self.appWindow.window?.performClose(nil) } }   // dev: is it all freed?
      if args.contains("--demo") { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.appWindow.js("{\"t\":\"demo\"}") } }   // dev: the promo video's app-window shot
      if let m = argValue("--mode") { DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.appWindow.js("{\"t\":\"mode\",\"m\":\"\(m == "sample" ? "sample" : "mine")\"}") } }   // dev
      if let t = argValue("--select") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.appWindow.js("{\"t\":\"select\",\"id\":\"\(t)\"}") } }   // dev
      if let p = argValue("--page") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.appWindow.show(page: p) } }
      if args.contains("--hittest") { DispatchQueue.main.asyncAfter(deadline: .now() + 2) {   // dev: which view gets a click where
        guard let w = self.appWindow.window, let frame = w.contentView?.superview else { return }
        let h = w.frame.height
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
          if let btn = w.standardWindowButton(b), let sv = btn.superview {
            let c = frame.convert(sv.convert(NSPoint(x: btn.frame.midX, y: btn.frame.midY), to: nil), from: nil)
            log("hit \(b == .closeButton ? "close" : b == .miniaturizeButton ? "minimise" : "zoom") button: \(frame.hitTest(c).map { String(describing: type(of: $0)) } ?? "nothing")") }
        }
        for (name, x, y) in [("left of the buttons", 4.0, h - 14), ("top strip, middle", 600.0, h - 14), ("top strip, right", w.frame.width - 60, h - 10),
                             ("sidebar top", 110.0, h - 40), ("main below strip", 600.0, h - 40), ("sidebar nav", 110.0, h - 120)] {
          let v = frame.hitTest(frame.convert(NSPoint(x: x, y: y), from: nil))
          log("hit \(name): \(v.map { String(describing: type(of: $0)) } ?? "nothing")\(v?.mouseDownCanMoveWindow == true ? " (moves window)" : "")")
        }
        NSApp.terminate(nil) } }
      return }
    SimInput.start()
    if benchMode, let fs = argValue("--fakescreens"), let b = NSScreen.screens.first.map({ CGRect(origin: .zero, size: $0.frame.size) }) {   // dev
      switch fs {
      case "row": fakeWorld = [1001: CGRect(x: -1920, y: b.minY - 98, width: 1920, height: 1080), 1002: b, 1003: CGRect(x: b.maxX, y: b.minY - 98, width: 1920, height: 1080)]
      case "above2": fakeWorld = [1001: CGRect(x: b.minX - 1533, y: b.minY - 1080, width: 1920, height: 1080), 1002: CGRect(x: b.minX + 387, y: b.minY - 1080, width: 1920, height: 1080), 1003: b]   // two monitors side by side above the laptop, meeting over it
      case "two": fakeWorld = [1001: CGRect(x: -1920, y: b.maxY - 1080, width: 1920, height: 1080), 1002: b]                      // one monitor left of the laptop, bottoms level
      case "portrait": fakeWorld = [1001: b, 1002: CGRect(x: b.maxX, y: b.minY - 420, width: 1080, height: 1920)]               // a monitor on its side, to the right
      case "big": fakeWorld = [1001: CGRect(x: b.minX - 300, y: b.minY - 1440, width: 2560, height: 1440), 1002: b]             // a 1440p monitor above, overhanging
      default: fakeWorld = [1001: CGRect(x: b.minX - 1533, y: b.minY - 1080, width: 1920, height: 1080), 1002: CGRect(x: b.minX + 387, y: b.minY - 1080, width: 1920, height: 1080), 1003: b]
      }
      // the monitors are ordinary 1× displays (--fakeretina: every one 2×, like the laptop)
      for (id, f) in fakeWorld where f != b { fakeScale[id] = args.contains("--fakeretina") ? 2 : 1 }
    }
    buildWalls()
    DeskIcons.shared = deskIcons
    deskIcons.onChange = { [weak self] in self?.sendDeskIcons(); self?.retuneTunnel() }
    deskIcons.resting = { [weak self] in guard let self else { return true }; return Tracker.idle || self.releasedAway }
    if benchMode, let n = argValue("--fakeicons").flatMap(Int.init) {    // dev: a column of n icons down the main display's right edge
      let main = fakeWorld.first(where: { $0.value.origin == .zero })?.value ?? NSScreen.screens.first.map { CGRect(origin: .zero, size: $0.frame.size) } ?? .zero
      let g = DeskIcons.geometry(), step = g.icon + g.text * 2.6 + 30, rows = max(1, Int((main.height - 60) / step))
      deskIcons.fake = (0..<n).map { i in let c = CGPoint(x: main.maxX - 66 - CGFloat(i / rows) * 108, y: main.minY + 73 + CGFloat(i % rows) * step); return (DeskIcons.box(c, g), DeskIcons.image(c, g)) }
    }
    deskIcons.start()
    tracker.onUpdate = { [weak self] r, live in self?.lastRects = r; self?.lastOwners = self?.tracker.owners ?? []; self?.dispatch(live: live) }
    tracker.onCursor = { [weak self] p in
      guard let self else { return }
      let w = self.walls.values.first(where: { $0.cgFrame.contains(p) })
      // the pointer moved to another screen: tell the one it left (cursor effects there fade out)
      if let prev = self.cursorWall, prev !== w { prev.send("{\"t\":\"cursorOff\"}") }
      self.cursorWall = w
      guard let w, w.paused == false else { return }
      w.cursor(p)
    }
    tracker.start()
    // nobody at the Mac (no mouse or key for 3 minutes): every page rests; the first touch wakes them. A once-a-second
    // look at the system's input clock, which needs no permission.
    if !benchMode || argValue("--idletest") != nil {
      let test = argValue("--idletest").flatMap(Double.init)
      var tick = 0
      idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
        guard let self else { return }
        tick += 1; if tick % 10 == 1 { self.checkPower() }
        let quiet = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let limit = test ?? Cfg.idleMinutes * 60
        let rest = limit > 0 && quiet > limit
        if rest != self.idleRest { self.idleRest = rest; log(rest ? "idle: resting" : "input: awake"); self.dispatch(live: false) }
      }
    }
    if let t = argValue("--lose-gl-at").flatMap(Double.init) { DispatchQueue.main.asyncAfter(deadline: .now() + t) {   // dev: force a WebGL context loss
      log("bench: losing every WebGL context")
      for w in self.walls.values { w.web.evaluateJavaScript("document.querySelectorAll('canvas').forEach(c => { const g = c.getContext('webgl2') || c.getContext('webgl'); const x = g && g.getExtension('WEBGL_lose_context'); x && x.loseContext(); }); null", completionHandler: nil) } } }
    for flag in ["--resize-at", "--resize-raw-at"] { if let t = argValue(flag).flatMap(Double.init) {   // dev: the screen changes size (while paused, say)
      DispatchQueue.main.asyncAfter(deadline: .now() + t) {
        for w in self.walls.values { var f = w.window.frame; f.size.width -= 200; w.window.setFrame(f, display: true) }
        log("bench: resized (\(flag))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
          if flag == "--resize-at" { self.buildWalls() }        // the real path: the screen's own size comes back
          else { for (id, w) in self.walls { if let s = NSScreen.screens.first(where: { $0.displayID == id }) { w.window.setFrame(s.frame, display: true) } } }
        } } } }
    if let js = argValue("--eval-each") {   // dev: ask every page the same question, now and then (--eval-every S)
      let every = Double(argValue("--eval-every") ?? "4") ?? 4
      Timer.scheduledTimer(withTimeInterval: every, repeats: true) { _ in
        for (id, w) in self.walls.sorted(by: { $0.key < $1.key }) { w.web.evaluateJavaScript("String((() => { \(js) })())") { r, e in log("eval [\(id)] \(r as? String ?? "error: \(e?.localizedDescription ?? "?")")") } } } }
    if let t = argValue("--cycle").flatMap(Double.init) {   // dev: switch through every theme, t seconds each (memory soak)
      var i = 0
      Timer.scheduledTimer(withTimeInterval: t, repeats: true) { _ in
        i += 1; let id = Cfg.themes[i % Cfg.themes.count].0; Cfg.themeOverride = id; log("bench: theme \(i) \(id)"); self.reloadAll() } }
    if let t = argValue("--reload-at").flatMap(Double.init) { DispatchQueue.main.asyncAfter(deadline: .now() + t) { log("bench: reloadAll"); self.reloadAll() } }   // dev
    if benchMode, let path = argValue("--uisteps"), let d = FileManager.default.contents(atPath: path),
       let steps = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {   // dev: a scripted walk through the app window
      // each step: at (s), ui (JS run in the app window), shot (save the window as <shot>.png), pages (JS asked of every
      // wallpaper page, answers logged as "PAGE <id> <answer>"). Settings it changes are put back when the run ends.
      let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName, saved = Cfg.d.persistentDomain(forName: domain) ?? [:]
      NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
        Cfg.d.setPersistentDomain(saved, forName: domain); Cfg.d.synchronize() }
      appWindow.show()
      for st in steps {
        let at = (st["at"] as? NSNumber)?.doubleValue ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + at) {
          if let js = st["ui"] as? String { self.appWindow.web?.evaluateJavaScript(js) { r, e in if let e { log("UI error: \(e.localizedDescription)") } else if let r { log("UI \(r)") } } }
          if let shot = st["shot"] as? String, let w = self.appWindow.web {
            w.takeSnapshot(with: nil) { img, _ in if let img, let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t), let png = r.representation(using: .png, properties: [:]) {
              try? png.write(to: URL(fileURLWithPath: shot + ".png")); log("SHOT \(shot)") } } }
          if let js = st["pages"] as? String {
            for (id, w) in self.walls.sorted(by: { $0.key < $1.key }) { w.web.evaluateJavaScript("String((() => { \(js) })())") { r, _ in log("PAGE \(id) \(st["label"] as? String ?? "") \(r as? String ?? "?")") } } }
        }
      }
    }
    if benchMode, let u = argValue("--unplug-at").flatMap(Double.init), !fakeWorld.isEmpty {   // dev: a display goes away mid-run (its page with it)
      DispatchQueue.main.asyncAfter(deadline: .now() + u) {
        let id = CGDirectDisplayID(argValue("--unplug") ?? "1001") ?? 1001
        log("bench: unplugging \(id)"); fakeWorld[id] = nil; fakeScale[id] = nil; self.walls[id]?.close(); self.walls[id] = nil
        self.resendDesks(); self.tracker.forceResend(); self.appWindow.pushState() } }
    if benchMode, let t = argValue("--crashtest").flatMap(Double.init) {   // dev: a real bad-pointer crash, to see the log catch it
      DispatchQueue.main.asyncAfter(deadline: .now() + t) { log("crashtest: writing through a bad pointer"); UnsafeMutablePointer<Int>(bitPattern: 0x18)!.pointee = 1 } }
    if benchMode, let t = argValue("--uistress").flatMap(Double.init) {   // dev: what a tester does in the window, as fast as a click every t s
      // the clicks change real settings: put them all back when the run ends, so the next test starts from the same place
      let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName, saved = Cfg.d.persistentDomain(forName: domain) ?? [:]
      NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
        Cfg.d.setPersistentDomain(saved, forName: domain); Cfg.d.synchronize() }
      appWindow.show(); var n = 0
      Timer.scheduledTimer(withTimeInterval: t, repeats: true) { _ in n += 1
        if n % 17 == 0 { log("uistress \(n): close and reopen the window"); self.appWindow.window?.performClose(nil)
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.appWindow.show() }; return }
        if n % 3 == 0, let menu = self.status?.menu {                     // and the menu bar: a random item, as a click would
          var items: [(NSMenu, Int, String)] = []
          func walk(_ m: NSMenu) { for (i, it) in m.items.enumerated() { if let sm = it.submenu { walk(sm) } else if it.isEnabled, it.action != nil,
            !["Quit", "Open", "Check", "What", "Restart", "Download", "About", "Report"].contains(where: { it.title.hasPrefix($0) }) { items.append((m, i, it.title)) } } }
          walk(menu)
          if let (m, i, title) = items.randomElement() { log("uistress \(n): menu \(title)"); m.performActionForItem(at: i) }
          return
        }
        self.appWindow.web?.evaluateJavaScript("""
        (() => { const T = ['railway','garden','estate','gallery','inkmap','celestial','snow','lava','wind','reef','tunnel','meadow','beach'];
          const r = Math.random(), th = T[Math.floor(Math.random() * T.length)], ids = (S.displays || []).map(d => d.id);
          let a;
          if (r < .3) a = { t: 'apply', theme: th };
          else if (r < .4) a = { t: 'applyDisplay', display: ids[Math.floor(Math.random() * ids.length)] || 1, theme: Math.random() < .2 ? null : th };
          else if (r < .5) a = { t: 'set', key: 'spanWorlds', value: Math.random() < .5 };
          else if (r < .6) a = { t: 'set', key: 'fps', value: [0, 30, 60][Math.floor(Math.random() * 3)] };
          else if (r < .68) a = { t: 'set', key: 'paused', value: Math.random() < .3 };
          else if (r < .76) a = { t: 'set', key: 'margin', value: Math.round(80 + Math.random() * 120) };
          else if (r < .84) a = { t: 'variant', theme: Math.random() < .5 ? 'lava' : 'wind', id: Math.random() < .5 ? 'blue' : 'IND' };
          else if (r < .9) a = Math.random() < .5 ? { t: 'set', key: 'idleMinutes', value: [0, 1, 3, 10][Math.floor(Math.random() * 4)] } : { t: 'set', key: ['reactWindows', 'reactStage', 'reactWidgets', 'reactCursor'][Math.floor(Math.random() * 4)], value: Math.random() < .5 };
          else if (r < .95) a = { t: 'reload' };
          else a = { t: 'desktop', display: ids[0] };
          send(a); return JSON.stringify(a); })()
        """) { r, e in log("uistress \(n): \(r as? String ?? "error \(e?.localizedDescription ?? "?")")") } } }
    if let t = argValue("--testpause"), let a = Double(t), !testPauseArmed {   /* bench: pause at a, resume at a + 8 */
      testPauseArmed = true
      DispatchQueue.main.asyncAfter(deadline: .now() + a) { self.userPaused = true; self.dispatch(live: false) }
      DispatchQueue.main.asyncAfter(deadline: .now() + a + 8) { self.userPaused = false; self.dispatch(live: false) } }
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
      self?.buildWalls(); self?.appWindow.pushState(); self?.appWindow.pushDesktop(); self?.checkGPUContexts() }
    let wnc = NSWorkspace.shared.notificationCenter
    wnc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.displaysAsleep = true; self?.dispatch(live: false); self?.updater.away() }
    wnc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.displaysAsleep = false; self?.dispatch(live: false); self?.checkGPUContexts() }
    let dnc = DistributedNotificationCenter.default()
    dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.locked = true; self?.dispatch(live: false); self?.updater.away() }
    dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.locked = false; self?.dispatch(live: false); self?.checkGPUContexts() }
    if !benchMode {
      LoginItem.refresh()
      // relaunched by an update while the screen is locked: start out knowing it (the lock notification came before us)
      if let d = CGSessionCopyCurrentDictionary() as? [String: Any], d["CGSSessionScreenIsLocked"] as? Bool == true { locked = true }
      updater.onChange = { [weak self] in self?.buildMenu(); self?.appWindow.pushState() }
      updater.isAway = { [weak self] in self?.asleep ?? false }
      updater.start()
      if Cfg.notesSeen == nil && !updater.justUpdated { Cfg.notesSeen = Cfg.version }   // a fresh install: nothing to announce
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.updater.cameUp() }
      if let from = argValue("--updated-from") { log("[update] updated from \(from) to \(Cfg.version)") }
      DistributedNotificationCenter.default().addObserver(forName: .init("app.tidewall.show"), object: nil, queue: .main) { [weak self] _ in self?.appWindow.show() }
      buildMenu()
      if Bundle.main.bundleIdentifier == nil, let i = NSImage(contentsOf: themesRoot.appendingPathComponent("ui/icon.png")) { NSApp.applicationIconImage = i }
      buildMainMenu { [weak self] in self?.appWindow.show(page: "about") }
      // opened by hand (not at login): show the window
      if Mover.offerIfNeeded() { return }                    // opened from Downloads: move to Applications first, then carry on from there
      if !args.contains("--background") || !Cfg.d.bool(forKey: "welcomed") { Cfg.d.set(true, forKey: "welcomed"); appWindow.show() }
    } else { Bench.start(self) }
    if args.contains("--usage") {           // log what the menu shows, every 2 s
      _ = usage.sample()
      Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
        guard let s = self?.usage.sample() else { return }
        log(String(format: "USAGE cpu=%.1f%% gpu=%.1f%% mem=%.0fMB procs=%d", s.cpu, s.gpu, s.memMB, s.procs)) }
    }
    for s in [SIGTERM, SIGINT] { signal(s, SIG_IGN); let src = DispatchSource.makeSignalSource(signal: s, queue: .main); src.setEventHandler { NSApp.terminate(nil) }; src.resume(); signalSources.append(src) }
  }
  var signalSources: [DispatchSourceSignal] = []
  func applicationWillTerminate(_ n: Notification) { walls.values.forEach { $0.close() } }

  // covered screens only go dormant after 15 s, and nothing else may call dispatch in the meantime: re-check
  var coverTimer: Timer?
  func scheduleCoverCheck() {
    guard coverTimer == nil, !coveredSince.isEmpty else { return }
    coverTimer = Timer.scheduledTimer(withTimeInterval: 16, repeats: false) { [weak self] _ in self?.coverTimer = nil; self?.dispatch(live: false) }
  }
  var stills: [CGDirectDisplayID: StillWall] = [:]
  /// let every page go, leaving each screen showing its last frame as a still picture
  /// the part of a display windows can use: below the menu bar, beside the Dock
  func usableFrame(_ s: NSScreen) -> CGRect {
    let h = NSScreen.screens.first?.frame.height ?? s.frame.maxY, v = s.visibleFrame
    return CGRect(x: v.minX, y: h - v.maxY, width: v.width, height: v.height)
  }
  func usableFrame(_ w: Wallpaper) -> CGRect { NSScreen.screens.first(where: { $0.displayID == w.screenID }).map { usableFrame($0) } ?? w.cgFrame }
  /// the moment a display is covered but for its menu bar and Dock, a picture of its page as it was last on show (a
  /// page that's been covered all along hasn't drawn anything worth keeping: WebKit doesn't render a hidden window)
  var pendingStills: [CGDirectDisplayID: NSImage] = [:]
  func keepStill(_ id: CGDirectDisplayID, _ w: Wallpaper) {
    guard let t = w.seenSince, ProcessInfo.processInfo.systemUptime - t > 5 else { return }
    w.web.takeSnapshot(with: nil) { [weak self] img, _ in if let self, let img, self.coveredSince[id] != nil { self.pendingStills[id] = img } }
  }
  /// one display's page let go, that picture left on show in its place (the menu bar and Dock still let it through)
  func releaseToStill(_ id: CGDirectDisplayID, _ w: Wallpaper, _ img: NSImage) {
    walls[id] = nil; dormant.insert(id); pendingStills[id] = nil
    stills[id]?.close(); stills[id] = StillWall(frame: w.window.frame, image: img)
    w.close()
  }
  func releaseToStills() {
    let ws = walls; walls = [:]; releasedAway = true
    for (id, w) in ws {
      w.web.takeSnapshot(with: nil) { [weak self] img, _ in
        guard let self else { w.close(); return }
        if let img, self.releasedAway {
          self.stills[id]?.close(); self.stills[id] = StillWall(frame: w.window.frame, image: img)
          if let path = argValue("--stilldump"), let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t), let png = r.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
        }
        w.close()
      }
    }
    log("away: released every page (still pictures on show)")
  }
  func buildWalls() {
    if args.contains("--ui-only") { return }                       // dev: the window alone, no wallpapers
    if !fakeWorld.isEmpty, let scr = NSScreen.screens.first {      // dev: pretend displays, one page each, in this app
      for (id, f) in fakeWorld where walls[id] == nil { walls[id] = Wallpaper(screen: scr, fakeID: id, fakeFrame: f) }
      tracker.forceResend(); return
    }
    let ids = Set(NSScreen.screens.map { $0.displayID })
    for (id, st) in stills where !ids.contains(id) { st.close(); stills[id] = nil }   // a display unplugged while away
    if releasedAway { return }                                     // away: the pages come back when you do
    for (id, w) in walls where !ids.contains(id) { w.close(); walls[id] = nil }
    for s in NSScreen.screens where (!benchMode || s == NSScreen.screens.first) && !dormant.contains(s.displayID) {
      if let w = walls[s.displayID] {
        let resized = w.window.frame.size != s.frame.size
        w.cgFrame = s.cgFrame; w.window.setFrame(s.frame, display: true); w.sendDesk()
        if resized { w.redrawIfPaused() } }
      else { let id = s.displayID, still = stills[id]; let w = Wallpaper(screen: s, hidden: still != nil); walls[id] = w
        if let still { w.onShown = { [weak self] in still.close(); if self?.stills[id] === still { self?.stills[id] = nil } }
          DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in if self?.stills[id] === still { w.window.alphaValue = 1; still.close(); self?.stills[id] = nil } } } }   // never leave a stale still up
    }
    tracker.forceResend()
  }

  /// a few seconds after the displays wake (external monitors take a moment to come back): any wallpaper left
  /// without its WebGL context is reloaded (the page usually notices by itself; this is the safety net)
  func checkGPUContexts(after delay: Double = 4) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self, !self.releasedAway else { return }
      for (id, w) in self.walls {
        w.web.evaluateJavaScript("!!(window.__twGLLost && window.__twGLLost())") { [weak self] r, _ in
          if (r as? Bool) == true { log("[\(id)] lost its GPU context: reloading"); self?.reloadWall(id) } }
      }
    }
  }
  /// a theme changed somewhere: worlds may have grown or shrunk, so every page hears its desk again
  func resendDesks() { for w in walls.values { w.sendDesk(); w.sendDeskIcons() } }
  func reloadAll() { walls.values.forEach { $0.close() }; walls = [:]; comeBackIfAway(); buildWalls() }
  /// Wind Tunnel with no model chosen runs on your desktop icons while you have some, and on its default model when you
  /// have none: when that flips (the first file lands on an empty desktop, the last one goes), reopen it, once things settle
  private var tunnelT: Timer?
  func retuneTunnel() {
    tunnelT?.invalidate()
    tunnelT = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
      guard let self else { return }
      let v = Cfg.variant("tunnel"), stale = self.walls.filter { Cfg.theme(for: $0.key) == "tunnel" && $0.value.loadedVariant != v }.map(\.key)
      for id in stale { self.reloadWall(id) }
      if !stale.isEmpty { self.appWindow.pushState() }
    }
  }
  /// On battery, as Settings asks: the same, calmer (pages draw at half their rate), or paused. Low Power Mode counts.
  private(set) var onBattery = false, lowPower = false, batteryPause = false, paceK = 1.0
  func checkPower() {
    let fake = Updater.devBuild ? ProcessInfo.processInfo.environment["TIDEWALL_FAKE_BATTERY"] : nil   // dev: test the battery paths plugged in
    let unplugged = fake.map { $0 == "1" } ?? ((IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String?) == kIOPSBatteryPowerValue)
    let low = fake == nil && ProcessInfo.processInfo.isLowPowerModeEnabled, bat = unplugged || low
    let pause = bat && Cfg.battery == 2, k = bat && Cfg.battery == 1 ? 2.0 : 1.0
    if unplugged != onBattery || low != lowPower { onBattery = unplugged; lowPower = low; appWindow.pushState() }
    if k != paceK { paceK = k; for w in walls.values { w.sendPace() }; log("power: pages at \(k == 1 ? "full" : "half") rate") }
    if pause != batteryPause { batteryPause = pause; log(pause ? "power: on battery, paused" : "power: running"); dispatch(live: false) }
  }
  func reloadWall(_ id: CGDirectDisplayID) { walls[id]?.close(); walls[id] = nil; comeBackIfAway(); buildWalls() }
  /// while the pages are let go (paused or away) a new theme or setting must still show: bring the pages back (the
  /// stills stay up until each new page has drawn), and let the away timer let them go again later
  private func comeBackIfAway() {
    guard releasedAway else { return }
    releasedAway = false; awayTimer?.invalidate(); awayTimer = nil
    DispatchQueue.main.async { [weak self] in self?.dispatch(live: false) }
  }

  var coveredSince: [CGDirectDisplayID: Double] = [:], dormant: Set<CGDirectDisplayID> = []
  /// whether the scene reshapes itself around this rect (Settings ▸ The wallpaper reacts to)
  func reacts(_ i: Int) -> Bool {
    let r = lastRects[i], owner = i < lastOwners.count ? lastOwners[i] : ""
    if Tracker.stageRects.contains("\(r)") { return Cfg.reactStage }
    if Tracker.widgetRects.contains("\(r)") || ["Notification Centre", "Notification Center", "WidgetKit Simulator"].contains(owner) { return Cfg.reactWidgets }
    return Cfg.reactWindows
  }
  func dispatch(live: Bool) {
    let now = ProcessInfo.processInfo.systemUptime
    for s in NSScreen.screens where !benchMode && !live {
      let id = s.displayID, frame = s.cgFrame
      // covered: a full-screen app over it. Mostly covered: windows over all of it but the menu bar and the Dock (a
      // maximized window), where the wallpaper only shows through, dimmed, behind them
      let full = uncoveredArea(frame, lastRects) < 1, covered = full || uncoveredArea(usableFrame(s), lastRects) < 1
      if covered { if coveredSince[id] == nil { coveredSince[id] = now; if !full, let w = walls[id] { keepStill(id, w) } } } else { coveredSince[id] = nil; pendingStills[id] = nil }
      if covered, let since = coveredSince[id], now - since > (full ? 15 : 30), let w = walls[id] {   // let its page go
        if full { w.close(); walls[id] = nil; dormant.insert(id); log("screen \(id) fully covered: released its page") }
        else if let img = pendingStills[id] { releaseToStill(id, w, img); log("screen \(id) covered but for its menu bar: a still picture, page released") }
        // (no picture of it yet: it has been covered since it opened, never drawn on show; it just rests)
      } else if !covered, dormant.contains(id), !releasedAway {                                               // visible again
        dormant.remove(id); buildWalls(); log("screen \(id) uncovered: page restored")   // (behind its still, if it had one, until it has drawn)
      }
    }
    scheduleCoverCheck()
    Tracker.idle = userPaused || asleep || idleRest || batteryPause
    // away for a while (locked, displays asleep, or paused from the menu): every page is let go, all of its memory with it,
    // and the wallpapers are rebuilt the moment you're back
    if userPaused || asleep || idleRest {
      // locked, asleep or paused: let go after 90 s; just idle at the desk: after 10 minutes
      let wait = userPaused || asleep ? (Double(argValue("--away") ?? "90") ?? 90) : (Double(argValue("--idleaway") ?? "600") ?? 600)
      if awayTimer == nil && !walls.isEmpty { awayTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
        guard let self, self.userPaused || self.asleep || self.idleRest else { return }
        self.releaseToStills() } }
    } else {
      awayTimer?.invalidate(); awayTimer = nil
      if releasedAway { releasedAway = false; log("back: rebuilding pages"); buildWalls() }
    }
    let hidden = NSScreen.screens.allSatisfy { s in dormant.contains(s.displayID) || coveredSince[s.displayID] != nil }
    if hidden != Tracker.allHidden { Tracker.allHidden = hidden; log(hidden ? "everything covered: idling" : "something visible again") }
    for w in walls.values {
      let world = Cfg.spanThemes.contains(Cfg.theme(for: w.screenID)) ? worldFrames(for: w.screenID) : [w.cgFrame]
      let idx = lastRects.indices.filter { r in world.contains { lastRects[r].intersects($0) } && reacts(r) }
      let mine = idx.map { lastRects[$0] }, names = idx.map { $0 < lastOwners.count ? lastOwners[$0] : "" }
      // never pause while windows are moving (a sliver of the town is still on show and must keep up)
      w.realRects = lastRects.filter { $0.intersects(w.cgFrame) }                 // (what's really over it, whatever the scene reacts to)
      let own = w.realRects
      // nothing to see but through the menu bar and the Dock (a maximized window): it rests, its last frame on show
      let pause = userPaused || asleep || idleRest || batteryPause || (!live && uncoveredArea(benchMode ? w.cgFrame : usableFrame(w), own) < 1)
      if !pause && w.ready && w.seenSince == nil { w.seenSince = now }
      w.update(rects: mine, owners: names, live: live, pause: pause)
    }
  }

  // MARK: menu
  func buildMenu() {
    if status == nil {
      status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
      status.button?.image = menuGlyph(); status.button?.toolTip = "Tidewall"
    }
    let m = NSMenu(); m.delegate = self
    let mono = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    if Cfg.hasNewNotes {
      let wn = ClosureItem("What’s New in Tidewall \(Cfg.version)…") { [weak self] in self?.appWindow.show(page: "whatsnew") }
      wn.attributedTitle = NSAttributedString(string: "What’s New in Tidewall \(Cfg.version)…", attributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)])
      m.addItem(wn); m.addItem(.separator())
    }
    switch updater.state {
    case .ready(let v):
      let u = ClosureItem("Restart to Update to \(v)") { [weak self] in self?.updater.install() }
      u.attributedTitle = NSAttributedString(string: "Restart to Update to \(v)", attributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold), .foregroundColor: NSColor.controlAccentColor])
      m.addItem(u); m.addItem(.separator())
    case .downloading(let v):
      let u = NSMenuItem(title: "Downloading Tidewall \(v)…", action: nil, keyEquivalent: ""); u.isEnabled = false; m.addItem(u); m.addItem(.separator())
    case .blocked(let v, let why):
      let u = ClosureItem("Move to Applications to Update to \(v)") { [weak self] in self?.updater.install() }; u.toolTip = why; m.addItem(u); m.addItem(.separator())
    default: break
    }
    for (i, title) in ["CPU  –", "GPU  –", "Memory  –", ""].enumerated() {
      let it = NSMenuItem(title: title, action: nil, keyEquivalent: ""); it.isEnabled = false; it.tag = 900 + i; it.isHidden = title.isEmpty
      it.attributedTitle = NSAttributedString(string: title, attributes: [.font: mono]); m.addItem(it)
    }
    m.addItem(.separator())
    let open = ClosureItem("Open Tidewall…") { [weak self] in self?.appWindow.show() }; open.keyEquivalent = ","
    open.attributedTitle = NSAttributedString(string: "Open Tidewall…", attributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)])
    m.addItem(open); m.addItem(.separator())
    func sub(_ title: String, _ items: [(String, Bool, () -> Void)]) {
      let it = NSMenuItem(title: title, action: nil, keyEquivalent: ""); let s = NSMenu()
      for (t, on, f) in items {
        let i = ClosureItem(t, f); i.state = on ? .on : .off
        let parts = t.components(separatedBy: " · ")
        if parts.count == 2 {           // "Name · tier": the resource tier in quiet grey after the name
          let a = NSMutableAttributedString(string: parts[0], attributes: [.font: NSFont.menuFont(ofSize: 0)])
          a.append(NSAttributedString(string: "   " + parts[1], attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
          i.attributedTitle = a
        }
        s.addItem(i)
      }
      it.submenu = s; m.addItem(it)
    }
    // the main theme: every display (choosing it clears any per-display themes)
    let showing = Set(NSScreen.screens.map { Cfg.theme(for: $0.displayID) })
    if NSScreen.screens.count > 1 {                          // several displays: "All Displays", then one menu each
      let names = displayNames()
      for s in NSScreen.screens {
        let id = s.displayID, own = Cfg.d.string(forKey: "theme.display.\(id)") != nil, main = s == NSScreen.screens.first
        let items: [(String, Bool, () -> Void)] = [(main ? "Default (\(Cfg.label(Cfg.theme)))" : "Same as Main (\(Cfg.label(Cfg.theme)))", !own,
            { Cfg.setTheme(nil, for: id); self.reloadWall(id); self.resendDesks(); self.buildMenu(); self.appWindow.pushState() })] +
          Cfg.themes.map { (tid, label) in (label, own && Cfg.theme(for: id) == tid,
            { Cfg.setTheme(tid, for: id); self.reloadWall(id); self.resendDesks(); self.buildMenu(); self.appWindow.pushState() }) }
        sub("\(names[id] ?? s.localizedName) — \(Cfg.label(Cfg.theme(for: id)))", items)
      }
    }
    sub(NSScreen.screens.count > 1 ? "All Displays" : "Wall", Cfg.themes.map { (id, label) in (label, NSScreen.screens.count > 1 ? Cfg.theme == id && !NSScreen.screens.contains { Cfg.d.string(forKey: "theme.display.\($0.displayID)") != nil } : showing.contains(id), { Cfg.clearDisplayThemes(); Cfg.theme = id; self.reloadAll(); self.buildMenu(); self.appWindow.pushState() }) })
    m.addItem(.separator())
    let ri = ClosureItem("Rest when idle") { Cfg.idleMinutes = Cfg.idleMinutes > 0 ? 0 : Cfg.idleLast; self.buildMenu(); self.appWindow.pushState() }; ri.state = Cfg.idleMinutes > 0 ? .on : .off
    let p = ClosureItem("Pause") { self.userPaused.toggle(); self.dispatch(live: false); self.buildMenu(); self.appWindow.pushState() }
    p.state = userPaused ? .on : .off; m.addItem(p); m.addItem(ri)
    let li = ClosureItem(LoginItem.blocked ? "Open at login (allow in System Settings…)" : "Open at login") {
      if LoginItem.blocked { SMAppService.openSystemSettingsLoginItems(); return }
      if let why = LoginItem.set(!LoginItem.enabled) { NSApp.activate(ignoringOtherApps: true); let a = NSAlert(); a.messageText = why; a.runModal() }
      self.buildMenu(); self.appWindow.pushState() }
    li.state = LoginItem.enabled && !LoginItem.blocked ? .on : .off; m.addItem(li)
    m.addItem(.separator())
    m.addItem(ClosureItem("Check for Updates…") { [weak self] in self?.updater.check(manual: true) })
    m.addItem(ClosureItem("Quit Tidewall") { NSApp.terminate(nil) })
    status.menu = m
  }
}

final class ClosureItem: NSMenuItem {
  let f: () -> Void
  init(_ t: String, _ f: @escaping () -> Void) { self.f = f; super.init(title: t, action: #selector(run), keyEquivalent: ""); target = self }
  required init(coder: NSCoder) { fatalError() }
  // after the click has been handled, not inside it: many actions rebuild the very menu this item belongs to
  @objc func run() { let f = self.f; DispatchQueue.main.async { f() } }
}

// MARK: - Bench: prints page + host stats; --sweep moves a synthetic window around to measure live updates

enum Bench {
  static func start(_ app: App) {
    let sweep = args.contains("--sweep")
    let secs = Double(argValue("--secs") ?? "12")!
    var t0 = 0.0
    app.tracker.onUpdate = { _, _ in }     // benches never use the real (changing) desktop
    let fixed: [CGRect] = args.contains("--nowin") ? [] : args.contains("--small") ? [CGRect(x: 560, y: 330, width: 520, height: 360)] : [CGRect(x: 221, y: 70, width: 1070, height: 875)] +
      [166.0, 337, 516, 679].map { CGRect(x: 16, y: $0, width: 130, height: 160) } + [CGRect(x: 1324, y: 794, width: 180, height: 180)]
    // --layout NAME: realistic desktops to test themes against (Stage Manager strip, widgets, tiling, crowding, screen edges)
    let R = { (x: Double, y: Double, w: Double, h: Double) in CGRect(x: x, y: y, width: w, height: h) }
    let layouts: [String: [(CGRect, String, Bool)]] = [
      "world3": [(R(-1250, -880, 760, 480), "Safari", false), (R(-150, -980, 420, 300), "Notes", false),
                 (R(1000, -930, 820, 520), "Code", false), (R(200, 170, 640, 420), "Slack", false), (R(900, 450, 460, 320), "Notes", false),
                 (R(1324, 794, 180, 180), "Notification Centre", false)],
      "sm": [(R(300, 40, 1050, 800), "WhatsApp", false), (R(14, 40, 140, 105), "Slack", true), (R(14, 200, 150, 120), "Google Chrome", true),
             (R(14, 375, 140, 115), "Code", true), (R(14, 545, 145, 110), "Claude", true), (R(14, 700, 140, 100), "Spotify", true),
             (R(1330, 790, 170, 170), "Notification Centre", false)],
      "tiled": [(R(16, 40, 732, 926), "Code", false), (R(756, 40, 740, 926), "Google Chrome", false)],
      "cascade": [(R(150, 80, 800, 600), "Google Chrome", false), (R(400, 220, 800, 560), "Slack", false), (R(760, 420, 640, 420), "Terminal", false)],
      "crowded": [(R(30, 50, 420, 300), "Finder", false), (R(470, 60, 380, 260), "Notes", false), (R(880, 40, 600, 380), "Google Chrome", false),
                  (R(40, 420, 520, 360), "Slack", false), (R(600, 470, 460, 330), "Terminal", false), (R(1090, 460, 400, 300), "Spotify", false),
                  (R(1320, 790, 170, 170), "Notification Centre", false), (R(1140, 790, 170, 170), "Notification Centre", false)],
      "edge": [(R(700, 300, 812, 682), "Code", false), (R(16, 16, 170, 170), "Notification Centre", false), (R(196, 16, 170, 170), "Notification Centre", false)],
      "widgets": [(R(1320, 790, 170, 170), "Notification Centre", false), (R(1320, 600, 170, 170), "Notification Centre", false), (R(40, 60, 344, 170), "Notification Centre", false), (R(1060, 480, 170, 170), "Notification Centre", false), (R(300, 200, 560, 420), "Google Chrome", false)],
      "mine": [(R(16, 193, 100, 130), "Slack", true), (R(16, 337, 118, 149), "Google Chrome", true), (R(16, 512, 118, 155), "Electron", true), (R(16, 675, 118, 147), "Claude", true),
               (R(-7, 263, 66, 82), "WindowManager", false), (R(-7, 441, 66, 82), "WindowManager", false), (R(-7, 622, 66, 82), "WindowManager", false), (R(-7, 777, 66, 82), "WindowManager", false),
               (R(1324, 794, 180, 180), "Notification Centre", false)],
      "big": [(R(16, 193, 100, 130), "Slack", true), (R(16, 337, 118, 149), "Google Chrome", true), (R(16, 512, 118, 155), "Electron", true), (R(16, 675, 118, 147), "Claude", true),
              (R(236, 146, 979, 676), "WhatsApp", false), (R(1324, 794, 180, 180), "Notification Centre", false)],
      "slack": [(R(16, 193, 100, 130), "WhatsApp", true), (R(16, 337, 118, 149), "Google Chrome", true), (R(16, 512, 118, 155), "Electron", true), (R(16, 675, 118, 147), "Claude", true),
                (R(231, 140, 1155, 670), "Slack", false), (R(1324, 794, 180, 180), "Notification Centre", false)],
      "showcase": [(R(250, 190, 620, 410), "Safari", false), (R(840, 430, 470, 320), "Notes", false)],
      "empty": []]
    var owners0 = ["Slack", "WhatsApp", "Notes", "Electron", "Claude", "Notification Centre"], rects0 = fixed, stage0: [CGRect] = []
    let choreo = argValue("--choreo").flatMap { Choreo(path: $0) }
    if let c = choreo { let a = c.at(0); rects0 = a.0; owners0 = a.1; stage0 = zip(a.0, a.2).filter { $0.1 }.map { $0.0 }
      c.pinCursor(0) }                                     // the real mouse must not reach the page while filming
    else if argValue("--layout") == "auto", !fakeWorld.isEmpty {     // dev: a big and a small window on every pretend display
      let names = ["Safari", "Code", "Slack", "Notes", "Mail", "Figma"]; var i = 0; rects0 = []; owners0 = []
      for (_, f) in fakeWorld.sorted(by: { $0.key < $1.key }) {
        rects0.append(CGRect(x: f.minX + f.width * 0.1, y: f.minY + max(40, f.height * 0.12), width: f.width * 0.46, height: f.height * 0.48)); owners0.append(names[i % 6]); i += 1
        rects0.append(CGRect(x: f.minX + f.width * 0.64, y: f.minY + f.height * 0.55, width: f.width * 0.24, height: f.height * 0.28)); owners0.append(names[i % 6]); i += 1 } }
    else if let name = argValue("--layout"), let l = layouts[name] { rects0 = l.map { $0.0 }; owners0 = l.map { $0.1 }; stage0 = l.filter { $0.2 }.map { $0.0 } }
    if !sweep { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      for r in stage0 { Tracker.stageRects.insert("\(r)") }
      app.lastRects = rects0; app.lastOwners = owners0; app.dispatch(live: false) } }
    // --hop S: the first window glides to a new spot (over 0.4 s), S seconds before the snapshot
    if let hop = argValue("--hop"), let before = Double(hop), !sweep {
      let start = secs - 1 - before - 0.4, from = fixed[0], to = from.offsetBy(dx: 380, dy: 200)
      for i in 0...12 { DispatchQueue.main.asyncAfter(deadline: .now() + max(2, start) + Double(i) * 0.4 / 12) {
        let t = Double(i) / 12, e = t * t * (3 - 2 * t)
        app.lastRects[0] = CGRect(x: from.minX + (to.minX - from.minX) * e, y: from.minY + (to.minY - from.minY) * e, width: from.width, height: from.height)
        app.dispatch(live: i < 12) } }
    }
    if sweep {
      Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
        if t0 == 0 { t0 = ProcessInfo.processInfo.systemUptime }
        let t = ProcessInfo.processInfo.systemUptime - t0
        guard let w = app.walls.values.first(where: { $0.cgFrame.origin == .zero }) ?? app.walls.values.first else { return }
        let f = w.cgFrame
        let r = CGRect(x: f.minX + f.width * (0.3 + 0.2 * sin(t * 1.3)), y: f.minY + f.height * (0.3 + 0.15 * cos(t)), width: 700, height: 500)
        app.lastRects = [r]; app.dispatch(live: true)
      }
    }
    Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
      for w in app.walls.values where w.cgFrame.origin == .zero {
        w.web.evaluateJavaScript("(()=>{try{return [(window.__prof?('JSms/frame='+(__prof.ms/Math.max(1,__prof.n)).toFixed(2)+' frames/s='+(__prof.n/((performance.now()-__prof.t0)/1000)).toFixed(1)):''),(typeof window.__dbg==='function'?__dbg():''), (typeof icons!=='undefined'?'icon0='+JSON.stringify(icons[0]&&{x:icons[0].x|0,y:icons[0].y|0,w:icons[0].w|0,h:icons[0].h|0})+' s@c='+(typeof curS==='function'&&icons[0]?curS(icons[0].x+icons[0].w/2,icons[0].y+icons[0].h/2).toFixed(0):'-')+' frames='+(typeof frameN!=='undefined'?frameN:'-')+' icons='+icons.length+' mix='+(typeof curMix!=='undefined'?curMix.toFixed(2):'-')+' from/to='+(typeof fromI!=='undefined'?fromI+'/'+toI:'-')+' morphT0='+(typeof morphT0!=='undefined'?(morphT0|0):'-')+' FB='+(typeof FB!=='undefined'&&!!FB)+' iconsSeen='+(typeof iconsSeen!=='undefined'?iconsSeen:'-'):''), devicePixelRatio, cv.width+'x'+cv.height, cv._scale, P.quality, Math.round(fpsEMA), fieldMs.toFixed(1), (window.__gl?window.__gl.drawingBufferWidth:0)+'x'+(window.__gl?window.__gl.drawingBufferHeight:0), paused].join(' ')}catch(e){return 'page loading'}})()") { r, _ in
          let pid = webPid(w.web)
          log("bench fps/fieldMs/buffer/paused: \(r ?? "nil")  webpid=\(pid)  polls=\(app.tracker.polls) avgPollMs=\(String(format: "%.2f", app.tracker.pollMs / Double(max(app.tracker.polls, 1))))")
        }
      }
    }
    // --frames DIR --every S: a numbered snapshot every S seconds (to watch motion frame by frame)
    // --film DIR: footage for the promo video. After --film-start s, the first window glides by --film-move dx,dy (points)
    // over --film-dur s while frames are taken as fast as they come, each named by its time (ms) since the film began.
    if let dir = argValue("--film") {
      let start = Double(argValue("--film-start") ?? "6")!, dur = Double(argValue("--film-dur") ?? "4")!, width = Double(argValue("--film-width") ?? "1920")!
      let mv = (argValue("--film-move") ?? "320,140").split(separator: ",").compactMap { Double($0) }, from = rects0.first ?? .zero
      var t0 = 0.0
      let enc = DispatchQueue(label: "film", qos: .userInitiated, attributes: .concurrent)
      DispatchQueue.main.asyncAfter(deadline: .now() + start) {
        t0 = ProcessInfo.processInfo.systemUptime
        let k = Double(argValue("--timescale") ?? "1") ?? 1
        if let c = choreo {                                  // scripted: windows, Stage Manager cards, widgets, the cursor
          var prev: [CGRect] = []
          Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { tm in
            let t = (ProcessInfo.processInfo.systemUptime - t0) * k, (r, o, sm) = c.at(t)
            Tracker.stageRects = Set(zip(r, sm).filter { $0.1 }.map { "\($0.0)" })
            app.lastRects = r; app.lastOwners = o; app.dispatch(live: r != prev && r.count == prev.count); prev = r
            c.pinCursor(t)
            if let p = c.cursor(t), let w = app.walls.values.first(where: { $0.cgFrame.origin == .zero }) { w.cursor(p) }
            if t > dur { tm.invalidate(); app.dispatch(live: false) }
          }
        } else {
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { tm in
          let t = ProcessInfo.processInfo.systemUptime - t0, a = 0.35, b = dur - 0.7
          let u = max(0, min(1, (t - a) / (b - a))), e = u * u * u * (u * (u * 6 - 15) + 10)       // smootherstep
          app.lastRects[0] = CGRect(x: from.minX + mv[0] * e, y: from.minY + mv[1] * e, width: from.width, height: from.height)
          app.dispatch(live: t > a && t < b)
          if t > dur { tm.invalidate(); app.dispatch(live: false) }
        }
        }
        func shoot() {
          let t = (ProcessInfo.processInfo.systemUptime - t0) * k
          guard !args.contains("--film-noshots") else { return }            // dev: the scripted desk only (CPU measurements)
          guard t <= dur, let w = app.walls.values.first(where: { $0.cgFrame.origin == .zero }) else { return }
          let cfg = WKSnapshotConfiguration(); cfg.snapshotWidth = NSNumber(value: width / 2)   // in points: ×2 on a retina screen
          w.web.takeSnapshot(with: cfg) { img, _ in
            shoot()                                        // the next one straight away; encoding happens off the main thread
            guard let img, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            enc.async { let r = NSBitmapImageRep(cgImage: cg)
              try? r.representation(using: .jpeg, properties: [.compressionFactor: 0.94])!.write(to: URL(fileURLWithPath: String(format: "%@/t%06d.jpg", dir, Int(t * 1000)))) }
          }
        }
        shoot()
      }
    }
    if let dir = argValue("--frames") {
      let every = Double(argValue("--every") ?? "0.25")!, start = Double(argValue("--from") ?? "6")!
      var n = 0
      DispatchQueue.main.asyncAfter(deadline: .now() + start) {
        Timer.scheduledTimer(withTimeInterval: every, repeats: true) { _ in
          guard let w = app.walls.values.first(where: { $0.cgFrame.origin == .zero }) else { return }
          let i = n; n += 1
          let cfg = WKSnapshotConfiguration(); cfg.snapshotWidth = 756
          w.web.takeSnapshot(with: cfg) { img, _ in
            if let img, let r = NSBitmapImageRep(data: img.tiffRepresentation!) { try? r.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: String(format: "%@/f%04d.png", dir, i))) }
          }
        }
      }
    }
    if let shot = argValue("--snapshot") {
      var a = 0.0
      Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in   // fake cursor walking a loop in open sea
        a += 0.035; app.walls.values.first(where: { $0.cgFrame.origin == .zero })?.cursor(CGPoint(x: 1380 + 70 * cos(a), y: 330 + 160 * sin(a * 0.5)))
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + secs - 1) {
        if !fakeWorld.isEmpty {                                  // every pretend display, and the desk it makes
          let base = (shot as NSString).deletingPathExtension
          var lay: [String] = []
          for (id, w) in app.walls { let f = w.cgFrame; lay.append("\"\(id)\":[\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))]")
            w.web.takeSnapshot(with: nil) { img, _ in
              if let img, let r = NSBitmapImageRep(data: img.tiffRepresentation!) { try? r.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(base)-\(id).png")) } } }
          try? "{\(lay.joined(separator: ","))}".write(toFile: "\(base)-layout.json", atomically: true, encoding: .utf8); log("snapshots -> \(base)-*.png")
          return
        }
        guard let w = app.walls.values.first(where: { $0.cgFrame.origin == .zero }) else { return }
        w.web.takeSnapshot(with: nil) { img, _ in
          if let img, let r = NSBitmapImageRep(data: img.tiffRepresentation!) { try? r.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: shot)); log("snapshot -> \(shot)") }
        }
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + secs) { NSApp.terminate(nil) }
  }
}

// one Tidewall at a time: opening a second copy shows the running one's window instead, unless this copy is newer
// (you downloaded an update by hand): then the old one is asked to quit and this one carries on
if !benchMode && !args.contains("--ui-only"), let id = Bundle.main.bundleIdentifier {
  let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != getpid() }
  if !others.isEmpty {
    let ver = { (a: NSRunningApplication) in a.bundleURL.flatMap { NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String } ?? "0" }
    if others.allSatisfy({ Updater.newer(Cfg.version, than: ver($0)) }) {
      log("[launch] replacing the running Tidewall \(others.map(ver).joined(separator: ", ")) with \(Cfg.version)")
      others.forEach { _ = $0.terminate() }
      let until = Date().addingTimeInterval(8)
      while others.contains(where: { !$0.isTerminated }) && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
      others.filter { !$0.isTerminated }.forEach { _ = $0.forceTerminate() }
    } else {
      DistributedNotificationCenter.default().postNotificationName(.init("app.tidewall.show"), object: nil, userInfo: nil, deliverImmediately: true)
      exit(0)
    }
  }
}
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

extension NSFont { func withWeight(_ w: NSFont.Weight) -> NSFont { NSFont.systemFont(ofSize: pointSize, weight: w) } }

/// a web view's content process id (private, guarded: -1 if it ever goes away)
func webPid(_ w: WKWebView) -> Int { w.responds(to: NSSelectorFromString("_webProcessIdentifier")) ? (w.value(forKey: "_webProcessIdentifier") as? Int) ?? -1 : -1 }

/// A scripted desktop for filming (--choreo file.json): windows with keyframes [[t, x, y, w, h], …] (eased between),
/// optional "from"/"until" times, Stage Manager cards ("sm": true), and a cursor path [[t, x, y], …]. Points, scene seconds.
struct Choreo {
  struct Win { let name: String; let keys: [[Double]]; let from: Double; let until: Double; let sm: Bool }
  let wins: [Win]; let cur: [[Double]]
  init?(path: String) {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    wins = (o["windows"] as? [[String: Any]] ?? []).map { w in Win(name: w["name"] as? String ?? "", keys: w["keys"] as? [[Double]] ?? [], from: w["from"] as? Double ?? -1e9,
                                                                   until: w["until"] as? Double ?? 1e9, sm: w["sm"] as? Bool ?? false) }
    cur = o["cursor"] as? [[Double]] ?? []
  }
  static func ease(_ keys: [[Double]], _ t: Double) -> [Double] {
    guard let f = keys.first else { return [] }
    if t <= f[0] { return Array(f.dropFirst()) }
    for (a, b) in zip(keys, keys.dropFirst()) where t <= b[0] {
      let u = (t - a[0]) / max(1e-6, b[0] - a[0]), e = u * u * u * (u * (u * 6 - 15) + 10)
      return zip(a.dropFirst(), b.dropFirst()).map { $0 + ($1 - $0) * e } }
    return Array(keys.last!.dropFirst())
  }
  func at(_ t: Double) -> ([CGRect], [String], [Bool]) {
    var r: [CGRect] = [], o: [String] = [], sm: [Bool] = []
    for w in wins where t >= w.from && t < w.until { let v = Choreo.ease(w.keys, t); guard v.count == 4 else { continue }
      r.append(CGRect(x: v[0], y: v[1], width: v[2], height: v[3])); o.append(w.name); sm.append(w.sm) }
    return (r, o, sm)
  }
  func cursor(_ t: Double) -> CGPoint? { let v = Choreo.ease(cur, t); return v.count == 2 ? CGPoint(x: v[0], y: v[1]) : nil }
  /// Routes the scripted cursor through the tracker's simulated-input path, so the Mac's real mouse (still polled by the
  /// tracker) can't send competing positions mid-take. No scripted cursor: parked far off screen.
  func pinCursor(_ t: Double) {
    let h = NSScreen.screens.first?.frame.height ?? 0, p = cursor(t) ?? CGPoint(x: -4000, y: -4000)
    SimInput.point = NSPoint(x: p.x, y: h - p.y)
  }
}

// MARK: - Updates

/// Tidewall keeps itself up to date from its GitHub releases, without an Apple Developer ID (the way VerbaSuper does):
///  1. Each release carries `update.json` beside the zip: version, zip URL, size, SHA-256, minimum macOS, notes, and an
///     Ed25519 signature over all of them (tools/update-sign.swift; CI signs in a job that runs no build scripts).
///  2. The app reads releases/latest/download/update.json on launch and every 6 h. Nothing in it is used until the
///     signature checks out against one of the public keys below. A newer version is downloaded, checked again
///     (size, SHA-256, signature, bundle id, version, code signature) and unpacked beside the app (same volume).
///  3. It's swapped in with plain renames and relaunched: by you ("Restart to Update"), or by itself while the screen
///     is locked. A detached helper waits for the new copy to report it came up; if it doesn't within 20 s the old
///     copy is put back, and that version isn't auto-installed again.
/// Files the app downloads itself carry no quarantine flag, so only the very first install meets Gatekeeper.
/// Development builds (build.sh without RELEASE=1) never update themselves, and only they honour the TIDEWALL_UPDATE_*
/// test variables.
final class Updater {
  enum Staged { case ok(URL, String), bad(String) }
  #if TIDEWALL_DEV
  static let devBuild = true
  #else
  static let devBuild = false
  #endif
  /// Test hooks, development builds only
  static let env: [String: String] = devBuild ? ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("TIDEWALL_UPDATE_") } : [:]
  /// The release-signing keys' public halves: the one CI signs with, and an offline backup (kept off GitHub) to sign
  /// with if the first is ever lost or has to be retired. Removing a key strands installs that only trust it.
  static let publicKeys = ["jjgDHnSJpmtt4178OEDmCcY5tCnQ3yryG8fnEPBxvyE=", "KsHXWESHYkG6q4hV1qc6fYixqZj5UcoS/34N+7Gwycw="]
  /// development builds only: a throwaway key to sign local test releases with (TIDEWALL_UPDATE_TESTKEY = its public half)
  static var trustedKeys: [String] { publicKeys + (env["TIDEWALL_UPDATE_TESTKEY"].map { [$0] } ?? []) }
  /// A release can carry a patch: only the files that changed since the release before it. A copy of the app on that
  /// release is cloned, patched, and must then match the release's code-signature hash exactly (the signature seals
  /// every file in the bundle), or the whole release is downloaded as before.
  struct Patch { let from: String, url: URL, sha: String, size: Int }
  static let feed = URL(string: env["TIDEWALL_UPDATE_FEED"] ?? "https://github.com/Keshav-Madhav/tidewall/releases/latest/download/update.json")!
  static let releasesPage = URL(string: "https://github.com/Keshav-Madhav/tidewall/releases/latest")!
  enum State: Equatable { case idle, checking, downloading(String), ready(String), blocked(String, String), skipped(String), upToDate, failed(String), off(String) }
  private(set) var state = State.idle { didSet { if state != oldValue { onChange?() } } }
  var onChange: (() -> Void)?
  var isAway: () -> Bool = { false }
  private var staged: URL?, stagedHash = "", lastCheck: Date?, timer: Timer?, notes = ""
  /// the app's folder isn't writable by this account (a standard account, /Applications owned by an administrator):
  /// updates still download, and installing asks for an administrator's password
  var needsAdmin: Bool { !fm.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path) }
  /// this launch is the first after an update installed
  private(set) var justUpdated = args.contains("--updated-from")
  private let fm = FileManager.default
  /// downloads (Caches) and the helper's notes to the next launch
  private let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("app.tidewall")
  private var dl: URL { caches.appendingPathComponent("update") }
  private var alive: URL { caches.appendingPathComponent("update-alive") }
  private var result: URL { caches.appendingPathComponent("update-result") }
  private var pidFile: URL { caches.appendingPathComponent("update-pid") }

  /// First thing at launch: this copy's pid, so an install's helper can stop exactly this process if it hangs
  func launching() {
    try? fm.createDirectory(at: caches, withIntermediateDirectories: true)
    try? "\(getpid())".write(to: pidFile, atomically: true, encoding: .utf8)
  }
  /// The wallpapers are up: an install's helper waits for this before it lets go of the previous copy
  func cameUp() { try? Cfg.version.write(to: alive, atomically: true, encoding: .utf8) }
  /// unpacked updates live beside the app, so every step of the swap is a rename on one volume (or, where this account
  /// can't write, in its own caches: the install then runs with an administrator's permission)
  private var work: URL { needsAdmin ? caches.appendingPathComponent("stage") : Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(".tidewall-update-\(getuid())") }

  /// why updates are off altogether (nil = they're on)
  var off: String? { Self.devBuild && Self.env["TIDEWALL_UPDATE_FEED"] == nil ? "This is a development build; it doesn't update itself." : nil }

  func start() {
    // what the last install's helper found
    if let r = try? String(contentsOf: result, encoding: .utf8) {
      let parts = r.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
      if parts.count == 2, parts[0] != "ok" { failed(parts[1]); log("[update] installing \(parts[1]) didn't work (\(parts[0])); keeping \(Cfg.version)") }
      else if parts.count == 2 { log("[update] \(parts[1]) installed"); justUpdated = true }
      try? fm.removeItem(at: result)
    }
    // leftovers from an earlier update, cleared before the first check (45 s) and after any helper is done with them
    // (it waits for update-alive, which this copy writes as soon as it has launched)
    DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
      guard let self, self.staged == nil else { return }
      switch self.state { case .checking, .downloading, .ready: return; default: break }
      try? self.fm.removeItem(at: self.work); try? self.fm.removeItem(at: self.dl); try? self.fm.removeItem(at: self.alive)
      try? self.fm.removeItem(at: self.pidFile)
    }
    if let why = off { state = .off(why); return }
    DispatchQueue.main.asyncAfter(deadline: .now() + (Self.env["TIDEWALL_UPDATE_FEED"] != nil ? 8 : 45)) { [weak self] in self?.check(manual: false) }
    timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check(manual: false) }
  }

  /// Why this copy can't replace itself (nil = it can). Only a copy macOS runs from a temporary place (opened straight
  /// from Downloads) can't: the button then moves it to Applications. A folder it can't write to just needs a password.
  var cantInstall: String? {
    Bundle.main.bundleURL.path.contains("/AppTranslocation/") ? "Move Tidewall to your Applications folder to get updates." : nil
  }

  /// versions whose install didn't come up: not installed automatically again
  private func failed(_ v: String) { var f = Cfg.d.dictionary(forKey: "update.failed") as? [String: Int] ?? [:]; f[v, default: 0] += 1; Cfg.d.set(f, forKey: "update.failed") }
  private func hasFailed(_ v: String) -> Bool { ((Cfg.d.dictionary(forKey: "update.failed") as? [String: Int])?[v] ?? 0) > 0 }

  /// For the app window: where things stand
  var status: [String: Any] {
    var o: [String: Any] = ["auto": Cfg.autoUpdate, "admin": needsAdmin]
    switch state {
    case .idle: o["s"] = "idle"
    case .checking: o["s"] = "checking"
    case .downloading(let v): o["s"] = "downloading"; o["v"] = v
    case .ready(let v): o["s"] = "ready"; o["v"] = v; o["notes"] = notes
    case .blocked(let v, let why): o["s"] = "ready"; o["v"] = v; o["blocked"] = why; o["notes"] = notes
    case .upToDate: o["s"] = "current"
    case .skipped(let v): o["s"] = "skipped"; o["v"] = v
    case .failed(let e): o["s"] = "failed"; o["err"] = e
    case .off(let why): o["s"] = "off"; o["err"] = why
    }
    if let d = lastCheck { o["checked"] = Int(d.timeIntervalSince1970) }
    return o
  }

  static func newer(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) { let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0; if p != q { return p > q } }
    return false
  }

  func check(manual: Bool, fromWindow: Bool = false) {
    if let why = off { state = .off(why); if manual { tell("Updates are off", why) }; return }
    switch state {
    case .checking, .downloading: return
    case .ready(let v): if manual { tell("Tidewall \(v) is ready", "Choose “Restart to Update to \(v)” in the menu bar.") }; return
    default: break }
    guard manual || fromWindow || Cfg.autoUpdate else { return }
    state = .checking
    var req = URLRequest(url: Self.feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    req.setValue("Tidewall/\(Cfg.version)", forHTTPHeaderField: "User-Agent")
    URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in DispatchQueue.main.async {
      guard let self else { return }
      self.lastCheck = Date()
      let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
      guard err == nil, code == 200, let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let v = o["version"] as? String, let urlS = o["url"] as? String, let url = URL(string: urlS), let sha = o["sha256"] as? String,
            let sig = (o["signature"] as? String).flatMap({ Data(base64Encoded: $0) }), let size = (o["size"] as? NSNumber)?.intValue,
            let minOS = o["minimumSystemVersion"] as? String, let notes = o["notes"] as? String else {
        let why = err?.localizedDescription ?? (code == 404 ? "no update information was found" : "the update feed answered \(code)")
        log("[update] check failed: \(why)"); self.state = .failed(why)
        if manual { self.tell("Couldn’t check for updates", "\(why.prefix(1).uppercased() + why.dropFirst()). You have version \(Cfg.version).") }; return }
      // nothing in the feed is trusted until its signature checks out (the zip itself is checked again after download)
      guard Self.signatureValid(sig, v, sha, size, minOS, notes) else {
        log("[update] the update feed's signature is invalid; ignoring it"); self.state = .failed("the update information isn't signed by Tidewall")
        if manual { self.tell("Couldn’t check for updates", "The update information wasn’t signed by Tidewall.") }; return }
      let os = ProcessInfo.processInfo.operatingSystemVersion
      guard Self.newer(v, than: Cfg.version) else { self.state = .upToDate; if manual { self.tell("Tidewall is up to date", "You have version \(Cfg.version), the newest.") }; return }
      guard !Self.newer(minOS, than: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)") else {
        self.state = .failed("Tidewall \(v) needs macOS \(minOS)"); if manual { self.tell("Tidewall \(v) needs macOS \(minOS)", "This Mac stays on \(Cfg.version).") }; return }
      guard url.scheme == "https" || Self.env["TIDEWALL_UPDATE_FEED"] != nil else { self.state = .failed("insecure update URL"); return }
      self.notes = notes
      if let why = self.cantInstall {        // don't fetch what can't be installed: offer to move it where it can be
        self.state = .blocked(v, why); if manual { self.tell("Tidewall \(v) is available", "\(why) Choose “Move to Applications” in Tidewall ▸ About.") }; return }
      // the patch, and the code-signature hash it must arrive at: trusted only under the second signature
      var patch: Patch? = nil, cdhash: String? = nil
      if let s2 = (o["signature2"] as? String).flatMap({ Data(base64Encoded: $0) }), let cd = o["cdhash"] as? String {
        let p = o["patch"] as? [String: Any], pf = p?["from"] as? String ?? "-", ps = p?["sha256"] as? String ?? "-", pz = (p?["size"] as? NSNumber)?.intValue ?? 0
        if Self.signature2Valid(s2, v, sha, size, minOS, notes, cd, pf, ps, pz) {
          cdhash = cd
          if pf == Cfg.version, let us = p?["url"] as? String, let pu = URL(string: us), pu.scheme == "https" || Self.env["TIDEWALL_UPDATE_FEED"] != nil {
            patch = Patch(from: pf, url: pu, sha: ps, size: pz) }
        } else { log("[update] the patch information isn't signed by Tidewall; ignoring it") }
      }
      if !manual && !fromWindow && self.hasFailed(v) { log("[update] \(v) failed to install before; waiting for a newer one (or Check for Updates…)"); self.state = .skipped(v); return }
      self.notes = notes                                  // plain text: never render it as HTML
      log("[update] \(v) is available (have \(Cfg.version)); downloading")
      if manual { self.tell("Tidewall \(v) is available", "It’s downloading now. When it’s ready, choose “Restart to Update” in the menu bar.") }
      if let patch, let cdhash { self.downloadPatch(v, patch, cdhash: cdhash) { ok in if !ok { self.download(v, url, sha, sig, size: size, minOS: minOS, notes: notes) } } }
      else { self.download(v, url, sha, sig, size: size, minOS: minOS, notes: notes) }
    } }.resume()
  }

  /// The release signature: over every field the app acts on (tools/update-sign.swift makes the same message)
  static func signatureValid(_ sig: Data, _ v: String, _ sha: String, _ size: Int, _ minOS: String, _ notes: String) -> Bool {
    let n = SHA256.hash(data: Data(notes.utf8)).map { String(format: "%02x", $0) }.joined()
    let msg = Data("tidewall-update-v1\n\(v)\n\(sha.lowercased())\n\(size)\n\(minOS)\n\(n)".utf8)
    return trustedKeys.contains { k in
      Data(base64Encoded: k).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }?.isValidSignature(sig, for: msg) ?? false }
  }
  /// The second signature (tools/update-sign.swift makes the same message): everything the first covers, plus the
  /// release's code-signature hash and its patch ("-" and 0 when there's none). Older copies ignore it.
  static func signature2Valid(_ sig: Data, _ v: String, _ sha: String, _ size: Int, _ minOS: String, _ notes: String,
                              _ cdhash: String, _ pFrom: String, _ pSha: String, _ pSize: Int) -> Bool {
    let n = SHA256.hash(data: Data(notes.utf8)).map { String(format: "%02x", $0) }.joined()
    let msg = Data("tidewall-update-v2\n\(v)\n\(sha.lowercased())\n\(size)\n\(minOS)\n\(n)\n\(cdhash.lowercased())\n\(pFrom)\n\(pSha.lowercased())\n\(pSize)".utf8)
    return trustedKeys.contains { k in
      Data(base64Encoded: k).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }?.isValidSignature(sig, for: msg) ?? false }
  }

  /// Fetch only what changed, lay it over a clone of this copy, and accept the result only if its code signature is
  /// exactly the release's. done(false): fetch the whole release instead.
  private func downloadPatch(_ v: String, _ p: Patch, cdhash: String, done: @escaping (Bool) -> Void) {
    state = .downloading(v); log("[update] \(v): fetching only what changed since \(p.from) (\(p.size / 1000) KB)")
    URLSession.shared.downloadTask(with: p.url) { [weak self] tmp, resp, err in
      guard let self else { return }
      let r: Staged = {
        guard let tmp, err == nil, (resp as? HTTPURLResponse)?.statusCode == 200 else { return .bad(err?.localizedDescription ?? "download failed") }
        return self.stagePatch(tmp, v, p, cdhash: cdhash)
      }()
      DispatchQueue.main.async {
        switch r {
        case .ok(let app, let hash): self.staged = app; self.stagedHash = hash; self.state = .ready(v); log("[update] \(v) is ready to install (patched)"); self.away(); done(true)
        case .bad(let why): log("[update] the \(v) patch didn't work (\(why)); fetching the whole release"); done(false)
        }
      }
    }.resume()
  }
  private func stagePatch(_ zip: URL, _ v: String, _ p: Patch, cdhash: String) -> Staged {
    guard (try? fm.attributesOfItem(atPath: zip.path))?[.size] as? Int == p.size else { return .bad("size mismatch") }
    guard let h = FileHandle(forReadingAtPath: zip.path) else { return .bad("can't read the download") }
    var hasher = SHA256(); while case let d = h.readData(ofLength: 1 << 20), !d.isEmpty { hasher.update(data: d) }; try? h.close()
    guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == p.sha.lowercased() else { return .bad("checksum mismatch") }
    let stage = work.appendingPathComponent(v), app = stage.appendingPathComponent("Tidewall.app")
    try? fm.removeItem(at: stage); try? fm.createDirectory(at: stage, withIntermediateDirectories: true)
    // this copy, cloned (on APFS: instant, and no extra space until files differ)
    guard run("/bin/cp", ["-cR", Bundle.main.bundleURL.path, app.path]).0 == 0 || run("/usr/bin/ditto", [Bundle.main.bundleURL.path, app.path]).0 == 0 else { return .bad("couldn't copy the app") }
    guard run("/usr/bin/ditto", ["-x", "-k", zip.path, stage.path]).0 == 0 else { return .bad("couldn't unpack the patch") }
    let del = stage.appendingPathComponent("deleted.txt")
    if let list = try? String(contentsOf: del, encoding: .utf8) {
      for line in list.split(separator: "\n").map(String.init) where !line.isEmpty && !line.hasPrefix("/") && !line.split(separator: "/").contains("..") {
        try? fm.removeItem(at: app.appendingPathComponent(line)) } }
    try? fm.removeItem(at: del)
    guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
          info["CFBundleIdentifier"] as? String == "app.tidewall", info["CFBundleShortVersionString"] as? String == v else { return .bad("the patched copy isn't Tidewall \(v)") }
    _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
    guard let hash = codeHash(app), hash.lowercased() == "cdhash=" + cdhash.lowercased() else { try? fm.removeItem(at: stage); return .bad("the patched copy isn't exactly the release") }
    return .ok(app, hash)
  }

  private func download(_ v: String, _ url: URL, _ sha: String, _ sig: Data, size: Int, minOS: String, notes: String) {
    state = .downloading(v)
    URLSession.shared.downloadTask(with: url) { [weak self] tmp, resp, err in
      guard let self else { return }
      // verify and unpack off the main thread (hashing ~130 MB takes a moment)
      let r: Staged = {
        guard let tmp, err == nil, (resp as? HTTPURLResponse)?.statusCode == 200 else { return .bad(err?.localizedDescription ?? "download failed") }
        return self.verifyAndStage(tmp, v, sha, sig, size: size, minOS: minOS, notes: notes)
      }()
      DispatchQueue.main.async {
        switch r {
        case .ok(let app, let hash): self.staged = app; self.stagedHash = hash; self.state = .ready(v); log("[update] \(v) is ready to install"); self.away()
        case .bad(let why): log("[update] \(v) rejected: \(why)"); self.state = .failed(why)
        }
      }
    }.resume()
  }

  private func verifyAndStage(_ zip: URL, _ v: String, _ sha: String, _ sig: Data, size: Int, minOS: String, notes: String) -> Staged {
    guard (try? fm.attributesOfItem(atPath: zip.path))?[.size] as? Int == size else { return .bad("size mismatch") }
    guard let h = FileHandle(forReadingAtPath: zip.path) else { return .bad("can't read the download") }
    var hasher = SHA256()
    while case let d = h.readData(ofLength: 1 << 20), !d.isEmpty { hasher.update(data: d) }
    try? h.close()
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard digest == sha.lowercased() else { return .bad("checksum mismatch") }
    guard Self.signatureValid(sig, v, sha, size, minOS, notes) else { return .bad("bad signature: not a Tidewall release") }
    let stage = work.appendingPathComponent(v)
    try? fm.removeItem(at: stage); try? fm.createDirectory(at: stage, withIntermediateDirectories: true)
    guard run("/usr/bin/ditto", ["-x", "-k", zip.path, stage.path]).0 == 0 else { return .bad("couldn't unpack the update") }
    let app = stage.appendingPathComponent("Tidewall.app")
    guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
          info["CFBundleIdentifier"] as? String == "app.tidewall", info["CFBundleShortVersionString"] as? String == v else { return .bad("the update isn't Tidewall \(v)") }
    _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
    guard let hash = codeHash(app) else { return .bad("the update's code signature is broken") }
    return .ok(app, hash)
  }

  /// The bundle's code-directory hash, if its signature (which seals every file in it) verifies; nil if it doesn't
  private func codeHash(_ app: URL) -> String? {
    guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).0 == 0 else { return nil }
    let out = run("/usr/bin/codesign", ["-dv", "--verbose=4", app.path]).1
    return out.split(separator: "\n").first { $0.hasPrefix("CDHash=") }.map(String.init)
  }

  @discardableResult private func run(_ tool: String, _ a: [String]) -> (Int32, String) {
    let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = a
    p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "") }
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit(); return (p.terminationStatus, String(data: out, encoding: .utf8) ?? "")
  }

  /// The screen locked or the displays slept: a good moment to install, if updates are automatic
  func away() {
    guard case .ready(let v) = state, Cfg.autoUpdate, cantInstall == nil, !needsAdmin, !hasFailed(v),   // a version that failed, or one that needs a password: only by hand
          isAway() || Self.env["TIDEWALL_UPDATE_INSTALL_NOW"] == "1" else { return }
    log("[update] installing while you're away"); install()
  }

  /// Swap the new version in and relaunch, through a detached helper: it waits for this process to exit, renames the
  /// old app aside and the new one into place, opens it, and waits up to 20 s for it to report it came up. If it
  /// doesn't, it puts the old app back and opens that; the next launch remembers the version failed.
  func install() {
    if case .blocked = state { if !Mover.moveNow() { NSWorkspace.shared.open(Self.releasesPage) }; return }   // (it moves, then updates from there)
    guard case .ready(let v) = state, let new = staged else { return }
    if let why = cantInstall { tell("Can’t update here", why); return }
    // the unpacked copy waited, maybe for hours: make sure it's exactly what was verified
    guard codeHash(new) == stagedHash, !stagedHash.isEmpty else {
      log("[update] the downloaded \(v) changed since it was checked; discarding it")
      staged = nil; try? fm.removeItem(at: work); state = .failed("the downloaded update changed; it will be fetched again"); return }
    let cur = Bundle.main.bundleURL.path, prev = work.appendingPathComponent("previous.app").path
    let q = shQuote
    // with the login item on, relaunch through it, so launchd keeps restarting Tidewall if it ever crashes
    // (only if launchd's loaded copy of the job runs exactly this app: it keeps the definition it read at login)
    let job = "gui/\(getuid())/\(LoginItem.label)", admin = needsAdmin
    // installed with an administrator's permission, the script runs as root: it opens Tidewall as you, not as root
    let opener = admin ? "/bin/launchctl asuser \(getuid()) /usr/bin/sudo -u \(shQuote(NSUserName())) /usr/bin/open" : "/usr/bin/open"
    let viaLogin = LoginItem.enabled
      ? "[ \"$(launchctl print \(job) 2>/dev/null | awk '/^\\tprogram = /{print substr($0, index($0, \"= \") + 2); exit}')\" = \"$EXE\" ] && launchctl kickstart \(job) >/dev/null 2>&1 || " : ""
    let script = """
    APP=\(q(cur)); NEW=\(q(new.path)); PREV=\(q(prev)); OK=\(q(alive.path)); RES=\(q(result.path)); PIDF=\(q(pidFile.path)); V=\(q(v))
    EXE="$APP/Contents/MacOS/Tidewall"
    launch() { \(viaLogin)\(opener) "$APP" --args --background --updated-from \(q(Cfg.version)); }
    # stop every Tidewall running from $APP: the pid it wrote, and any other whose executable is exactly $EXE
    stop() { for sig in TERM TERM TERM KILL; do
        ps=""; p=$(cat "$PIDF" 2>/dev/null); [ -n "$p" ] && [ "$(ps -o comm= -p "$p" 2>/dev/null)" = "$EXE" ] && ps="$p"
        for q in $(pgrep -x Tidewall); do [ "$(ps -o comm= -p "$q" 2>/dev/null)" = "$EXE" ] && ps="$ps $q"; done
        [ -z "$ps" ] && return 0
        kill -$sig $ps 2>/dev/null; sleep 1; done; }
    while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
    rm -rf "$PREV"; rm -f "$OK" "$PIDF"
    if ! mv "$APP" "$PREV"; then echo "failed $V" > "$RES"; launch; exit 0; fi
    if ! mv "$NEW" "$APP"; then mv "$PREV" "$APP"; echo "failed $V" > "$RES"; launch; exit 0; fi
    launch
    i=0; while [ $i -lt 300 ]; do
      if [ "$(cat "$OK" 2>/dev/null)" = "$V" ]; then rm -rf "$PREV"; echo "ok $V" > "$RES"; exit 0; fi
      sleep 0.2; i=$((i+1)); done
    # it didn't come up within 60 s: stop it, put the previous copy back, open that
    stop
    if mv "$APP" "$APP.failed"; then
      if mv "$PREV" "$APP"; then rm -rf "$APP.failed"; else mv "$APP.failed" "$APP"; fi
    fi
    echo "rolledback $V" > "$RES"; launch
    """
    if admin {
      // macOS asks for an administrator's password; the installer then runs as root, detached, and waits for this copy to quit
      let f = caches.appendingPathComponent("update-install.sh")
      guard (try? script.write(to: f, atomically: true, encoding: .utf8)) != nil else { tell("Couldn’t install the update", "Tidewall couldn’t prepare the installer."); return }
      let aq = { (s: String) in "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
      let src = "do shell script \"/bin/sh \" & quoted form of \(aq(f.path)) & \" >/dev/null 2>&1 &\" with prompt \(aq("Tidewall wants to install version \(v). It needs an administrator’s permission because of where it’s installed.")) with administrator privileges"
      NSApp.activate(ignoringOtherApps: true)
      var err: NSDictionary?
      _ = NSAppleScript(source: src)?.executeAndReturnError(&err)
      if let err { let code = (err[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        log("[update] the installer wasn't allowed to run (\(code))"); if code != -128 { tell("Couldn’t install the update", "\(err[NSAppleScript.errorMessage] ?? "macOS didn’t allow it.")") }; return }
    } else {
      guard spawnDetached(script) else { log("[update] couldn't start the installer"); state = .failed("couldn't start the installer"); return }
    }
    log("[update] installing \(v); relaunching")
    NSApp.terminate(nil)
  }

  private func tell(_ title: String, _ body: String) {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert(); a.messageText = title; a.informativeText = body; a.icon = NSApp.applicationIconImage; a.runModal()
  }
}

/// Runs a /bin/sh script that outlives this process: its own session (so launchd tidying up the login item's process
/// group can't take it down) and a clean environment (nothing of ours leaks into whatever it opens).
func spawnDetached(_ script: String) -> Bool {
  var attr: posix_spawnattr_t? = nil; posix_spawnattr_init(&attr)
  posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
  var pid: pid_t = 0
  let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(script), nil]
  let envp: [UnsafeMutablePointer<CChar>?] = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=\(NSHomeDirectory())", "USER=\(NSUserName())", "TMPDIR=\(NSTemporaryDirectory())"]
    .map { (e: String) -> UnsafeMutablePointer<CChar>? in strdup(e) } + [nil]
  let rc = posix_spawn(&pid, "/bin/sh", nil, &attr, argv, envp)
  posix_spawnattr_destroy(&attr); argv.forEach { free($0) }; envp.forEach { free($0) }
  return rc == 0
}
func shQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

// MARK: - Move to Applications

/// Opened from Downloads (or anywhere outside an Applications folder), Tidewall offers once to move itself there:
/// only from there can it open at login and update itself. Until a downloaded app is moved, macOS runs it from a
/// temporary read-only copy (App Translocation), so the original is found through the Security framework.
enum Mover {
  static func inApplications(_ app: URL) -> Bool {
    let parent = app.deletingLastPathComponent().path
    return ["/Applications", NSHomeDirectory() + "/Applications"].contains { parent == $0 || parent.hasPrefix($0 + "/") }
  }
  /// opens `app` once this copy has quit; --moved stops the opened copy from offering to move again
  static func relaunch(_ app: URL) -> Bool {
    guard spawnDetached("while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \(shQuote(app.path)) --args --moved") else { return false }
    NSApp.terminate(nil); return true
  }
  static func unquarantine(_ app: URL) {
    let x = Process(); x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr"); x.arguments = ["-dr", "com.apple.quarantine", app.path]
    try? x.run(); x.waitUntilExit()
  }
  /// where the app really is (not the translocated copy it's running from)
  static var original: URL {
    let u = Bundle.main.bundleURL
    guard u.path.contains("/AppTranslocation/"), let h = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
          let f = dlsym(h, "SecTranslocateCreateOriginalPathForURL") else { return u }
    typealias Fn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
    return (unsafeBitCast(f, to: Fn.self)(u as CFURL, nil)?.takeRetainedValue() as URL?) ?? u
  }
  /// About ▸ Move to Applications (a copy macOS runs from Downloads can't update itself): move it now, no question
  static func moveNow() -> Bool { offerIfNeeded(force: true) }
  /// true when it's moving: this copy then quits and the moved one opens
  static func offerIfNeeded(force: Bool = false) -> Bool {
    let test = force || Updater.env["TIDEWALL_UPDATE_MOVE_TEST"] == "1"   // asked for (or a development test): no question
    guard force || !args.contains("--moved"), force || !Updater.devBuild || test else { return false }
    let fm = FileManager.default, src = original
    // already in Applications, but still run from a translocated copy (unzipped there rather than moved by Finder):
    // clear the quarantine flag you've already approved and open the real one, once
    if inApplications(src) {
      guard src != Bundle.main.bundleURL else { return false }
      unquarantine(src); log("[move] reopening \(src.path) from where it is"); return relaunch(src)
    }
    guard test || !Cfg.d.bool(forKey: "moveDeclined") else { return false }
    let apps = Updater.env["TIDEWALL_UPDATE_MOVE_DEST"].map { URL(fileURLWithPath: $0) }
      ?? (fm.isWritableFile(atPath: "/Applications") ? URL(fileURLWithPath: "/Applications") : fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"))
    let dest = apps.appendingPathComponent("Tidewall.app")
    // already installed, and at least as new (say an old download opened by mistake): use that one, never downgrade it
    if let have = NSDictionary(contentsOf: dest.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String,
       !Updater.newer(Cfg.version, than: have) {
      log("[move] Tidewall \(have) is already in \(apps.path); opening that"); return relaunch(dest)
    }
    if !test {
      NSApp.activate(ignoringOtherApps: true)
      let a = NSAlert(); a.icon = NSApp.applicationIconImage
      a.messageText = "Move Tidewall to your Applications folder?"
      a.informativeText = "From there it can open when you log in and keep itself up to date. You only do this once."
      a.addButton(withTitle: "Move to Applications"); a.addButton(withTitle: "Not Now")
      guard a.runModal() == .alertFirstButtonReturn else { Cfg.d.set(true, forKey: "moveDeclined"); return false }
    }
    do {
      try fm.createDirectory(at: apps, withIntermediateDirectories: true)
      if fm.fileExists(atPath: dest.path) {                         // an older Tidewall; anything else named that is left alone
        guard NSDictionary(contentsOf: dest.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String == "app.tidewall" else {
          throw NSError(domain: "Tidewall", code: 1, userInfo: [NSLocalizedDescriptionKey: "Something else called Tidewall.app is already in \(apps.path)."]) }
        try fm.trashItem(at: dest, resultingItemURL: nil)
      }
      try fm.copyItem(at: src, to: dest)
    } catch {
      Cfg.d.set(true, forKey: "moveDeclined")                     // don't ask at every launch; Settings ▸ Updates explains
      let a = NSAlert(); a.messageText = "Couldn’t move Tidewall"; a.informativeText = error.localizedDescription; a.runModal(); return false }
    unquarantine(dest)          // you've opened it once already (Gatekeeper is done with it): no second translocation
    try? fm.trashItem(at: src, resultingItemURL: nil)                 // the copy in Downloads
    log("[move] moved to \(dest.path)"); return relaunch(dest)
  }
}

/// A see-through strip over the page's title-bar area that behaves like a title bar: drag moves the window,
/// double-click does what System Settings ▸ Desktop & Dock says (zoom, minimise or nothing).
final class TitlebarDrag: NSView {
  override var mouseDownCanMoveWindow: Bool { true }
  override func mouseDown(with e: NSEvent) {
    guard let w = window else { return }
    if e.clickCount == 2 {
      switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
      case "Minimize": w.performMiniaturize(nil)
      case "None": break
      default: w.performZoom(nil) }
      return
    }
    w.performDrag(with: e)
  }
}
