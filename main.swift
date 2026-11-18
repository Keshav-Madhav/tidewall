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
import WebKit
import IOKit
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
  static func clearDisplayThemes() { for k in d.dictionaryRepresentation().keys where k.hasPrefix("theme.display.") { d.removeObject(forKey: k) } }
  static let themes: [(String, String)] = [("estate", "Marauders · very low"), ("gallery", "Gallery · none"), ("wind", "Wind Map · medium"), ("lava", "Lava Lamp · low"),
    ("tunnel", "Wind Tunnel · high"), ("reef", "Koi Reef · medium"), ("snow", "Snowfall · low"), ("celestial", "Celestial Atlas · none"),
    ("inkmap", "Ink Map · very low"), ("garden", "Garden Plan · very low"), ("railway", "Model Railway · very low"), ("meadow", "Meadow · high"), ("beach", "Beach · medium")]
  /// each theme's own sub-choice (Wind Map's region, Lava Lamp's colours, …), declared in themes/variants.json
  static var variantOverride: String?
  static func variant(_ t: String) -> String? { (t == theme ? variantOverride : nil) ?? d.string(forKey: "variant.\(t)") ?? (t == "wind" ? homeRegion : nil) }
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
  static var margin: Double { get { d.object(forKey: "margin") as? Double ?? 140 } set { d.set(newValue, forKey: "margin") } }
  static var fps: Double { get { d.object(forKey: "fps") as? Double ?? 0 } set { d.set(newValue, forKey: "fps") } }
  /// seeds the generated names (your walker, the strangers); stable across launches
  static var seed: Int { if let v = d.object(forKey: "seed") as? Int { return v }; let v = Int.random(in: 1..<Int(Int32.max)); d.set(v, forKey: "seed"); return v }
  /// pause the animation when nobody has touched the mouse or keyboard for a while; any input brings it straight back
  static var restWhenIdle: Bool { get { d.object(forKey: "restWhenIdle") as? Bool ?? true } set { d.set(newValue, forKey: "restWhenIdle") } }
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
// the LaunchAgent appends to ~/Library/Logs/Tidewall.log forever: start over once it passes 5 MB
if var st = Optional(stat()), fstat(STDOUT_FILENO, &st) == 0, st.st_size > 5_000_000, (st.st_mode & S_IFMT) == S_IFREG { ftruncate(STDOUT_FILENO, 0) }

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
func earlyScript(fps: Double, opaque: Bool) -> String { """
(() => {
  const post = m => webkit.messageHandlers.host.postMessage(m);
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
      const g = gc.call(this, type, Object.assign({}, opts, { stencil: false, depth: false, alpha: window.__opaque === false }));   // no theme uses depth or the stencil mask: no buffers for them
      window.__gl = g; return g;
    }
    return gc.call(this, type, opts);
  };
  // Frame pacing: the pages self-cap at ~30 fps but still wake every vsync (60–120 Hz on ProMotion).
  // Only wake when a frame is actually due.
  if (\(fps) <= 0) return;
  const raf = window.requestAnimationFrame.bind(window), iv = 1000 / \(fps);
  let due = 0, lastT = -1, go = false;
  // between frames, sleep on a timer instead of waking at every vsync just to skip it (4× fewer wake-ups at 120 Hz)
  window.requestAnimationFrame = cb => raf(function tick(t) {
    if (t !== lastT) { lastT = t; go = t + 2 >= due; if (go) due = Math.max(due + iv, t); }
    if (!go) { const wait = due - t - 6; if (wait > 4) setTimeout(() => raf(tick), wait); else raf(tick); return; }
    if (window.__prof) { const a = performance.now(); cb(t); const p = window.__prof; p.n++; p.ms += performance.now() - a; } else cb(t);
  });
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
  static weak var anyWeb: WKWebView?
  var cgFrame: CGRect                         // screen in CG global coords (top-left origin), points
  let window: NSWindow
  let web: WKWebView
  var ready = false
  var paused: Bool?
  var lastIcons = "", lastMask = "", lastWins = ""
  var pending: (() -> Void)?
  var onShown: (() -> Void)?                  // called once a page that started hidden has drawn and is on show

  init(screen: NSScreen, hidden: Bool = false) {
    screenID = screen.displayID
    cgFrame = screen.cgFrame
    let cfg = WKWebViewConfiguration()
    // every screen's page in ONE web process: the engine, its libraries and caches are paid for once, not per display
    if let r = Wallpaper.anyWeb, cfg.responds(to: NSSelectorFromString("_setRelatedWebView:")) { cfg.perform(NSSelectorFromString("_setRelatedWebView:"), with: r) }
    cfg.setURLSchemeHandler(SchemeHandler(), forURLScheme: "tidewall")
    cfg.suppressesIncrementalRendering = true
    unlockHighRefresh(cfg.preferences)

    let ucc = cfg.userContentController
    ucc.addUserScript(WKUserScript(source: earlyScript(fps: stock ? 0 : Cfg.fps, opaque: !stock && !args.contains("--no-opaque")), injectionTime: .atDocumentStart, forMainFrameOnly: true))
    ucc.addUserScript(WKUserScript(source: lateScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
    window.ignoresMouseEvents = true
    window.isOpaque = true
    window.backgroundColor = NSColor(red: 0.914, green: 0.847, blue: 0.706, alpha: 1)
    window.hasShadow = false
    window.isReleasedWhenClosed = false
    web = WKWebView(frame: NSRect(origin: .zero, size: screen.frame.size), configuration: cfg)
    if Wallpaper.anyWeb == nil { Wallpaper.anyWeb = web }
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
    window.setFrame(screen.frame, display: false)
    if hidden { window.alphaValue = 0 }      // built behind the still picture; shown once it has drawn
    window.orderFront(nil)
    load()
  }

  func load() {
    ready = false; paused = nil; lastIcons = ""; lastMask = ""; lastWins = ""; wantsCursor = true
    let page = ["beach": "flat", "meadow": "meadow", "inkmap": "inkmap", "celestial": "celestial", "snow": "snow", "reef": "reef", "wind": "wind", "lava": "lava", "tunnel": "tunnel", "gallery": "gallery", "garden": "garden", "railway": "railway"][Cfg.theme(for: screenID)] ?? "estate"
    let v = Cfg.variant(Cfg.theme(for: screenID)).flatMap { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) }.map { "&v=\($0)" } ?? ""
    web.load(URLRequest(url: URL(string: "tidewall://app/\(page).html?wallpaper=1\(v)\(Cfg.siteQuery)")!))
  }

  var wantsCursor = true                    // a theme that ignores the pointer says so ("nocursor"): no 120 Hz messages for it
  /// where this screen sits among all of them (points, top-left origin): themes continue one world across displays
  /// (the sky, the map, the painted panorama) and never repeat the same thing on every screen
  func sendDesk() {
    var frames = NSScreen.screens.map { $0.cgFrame }, main = NSScreen.screens.first?.cgFrame ?? cgFrame, me = cgFrame
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
    send("{\"t\":\"desk\",\"x\":\(me.minX - u.minX),\"y\":\(me.minY - u.minY),\"w\":\(me.width),\"h\":\(me.height),\"uw\":\(u.width),\"uh\":\(u.height),\"i\":\(i),\"n\":\(frames.count),\"mx\":\(main.midX - u.minX),\"my\":\(main.midY - u.minY),\"mw\":\(main.width),\"mh\":\(main.height)}")
  }
  func cursor(_ p: CGPoint) {
    guard wantsCursor else { return }
    let k = window.backingScaleFactor
    send("{\"t\":\"cursor\",\"x\":\(Int((p.x - cgFrame.minX) * k)),\"y\":\(Int((p.y - cgFrame.minY) * k))}")
  }

  func close() { web.stopLoading(); window.orderOut(nil); window.close() }

  func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
    let s = "\(m.body)"
    if s == "nocursor" { wantsCursor = false; return }
    if s == "ready" && window.alphaValue < 1 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in guard let self else { return }
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.35; self.window.animator().alphaValue = 1 } completionHandler: { self.onShown?(); self.onShown = nil } }
    }
    if s == "ready" { ready = true; sendDesk(); send("{\"t\":\"me\",\"seed\":\(Cfg.seed)}")
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

  /// rects: windows on this screen in CG global points
  private var lastArgs: ([CGRect], [String], Bool, Bool)?
  func update(rects: [CGRect], owners: [String], live: Bool, pause: Bool) {
    lastArgs = (rects, owners, live, pause)
    guard ready else { pending = { [weak self] in self?.update(rects: rects, owners: owners, live: live, pause: pause) }; return }
    if pause != paused { paused = pause; send("{\"t\":\"pause\",\"v\":\(pause)}") }
    if pause { return }
    let k = window.backingScaleFactor, m = Cfg.margin, o = cgFrame.origin
    let local = rects.map { $0.offsetBy(dx: -o.x, dy: -o.y) }
    let icons = local.map { r -> String in
      let q = r.insetBy(dx: -m, dy: -m)
      return "[\(Int(q.minX * k)),\(Int(q.minY * k)),\(Int(q.maxX * k)),\(Int(q.maxY * k))]"
    }.joined(separator: ",")
    // raw window rects + app names (themes that draw *around* the real window edge, e.g. Estate)
    let raw = local.map { "[\(Int($0.minX * k)),\(Int($0.minY * k)),\(Int($0.maxX * k)),\(Int($0.maxY * k))]" }.joined(separator: ",")
    let names = String(data: try! JSONSerialization.data(withJSONObject: owners), encoding: .utf8)!
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
  var displayID: CGDirectDisplayID { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID }
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

  static let idleInterval = 0.15
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
    if t - lastCursorT >= 1.0 / 120 {           // cursor at display rate (the celestial cursor hole sits exactly on the pointer)
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
  static func read(excluding me: pid_t) -> [(CGRect, String)] {
    stageRects.removeAll()
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
    var out: [(CGRect, String)] = []
    for w in list {
      guard let layer = w[kCGWindowLayer as String] as? Int,
            let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
            let b = w[kCGWindowBounds as String] as? NSDictionary,
            let r = CGRect(dictionaryRepresentation: b) else { continue }
      let owner = w[kCGWindowOwnerName as String] as? String ?? ""
      let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
      // normal windows + Stage Manager strip (layer 0); desktop widgets live on a desktop-ish layer
      let widget = layer < 0 && (owner == "Notification Centre" || owner == "Notification Center")
      guard (layer == 0 || widget), alpha > 0.05, r.width >= 40, r.height >= 40 else { continue }
      // Stage Manager thumbnails + their app proxies share a rect: keep one, named after the app
      if let i = out.firstIndex(where: { $0.0 == r }) { if out[i].1 == "WindowManager" { out[i].1 = owner }; stageRects.insert("\(r)") } else { out.append((r, owner)) }
      if owner == "WindowManager" { stageRects.insert("\(r)") }
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
    let c = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.size))
    for p in buf.prefix(Int(c)) where p > 0 && p != me && resp(p) == me { pids.append(p) }
    return pids
  }
  private func rusage(_ pid: pid_t) -> rusage_info_v4? {
    var ri = rusage_info_v4()
    let r = withUnsafeMutablePointer(to: &ri) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
    return r == 0 ? ri : nil
  }
  /// GPU busy time (ns) the driver has billed to our pids (WebKit's GPU work is billed to the app).
  private func gpuNs(_ pids: Set<pid_t>) -> UInt64 {
    // GPU user clients aren't "matching services": walk the registry and pick them out
    var it: io_iterator_t = 0
    guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &it) == KERN_SUCCESS else { return 0 }
    defer { IOObjectRelease(it) }
    var total: UInt64 = 0
    while case let e = IOIteratorNext(it), e != 0 {
      defer { IOObjectRelease(e) }
      guard IOObjectConformsTo(e, "AGXDeviceUserClient") != 0 else { continue }
      var props: Unmanaged<CFMutableDictionary>?
      guard IORegistryEntryCreateCFProperties(e, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS, let d = props?.takeRetainedValue() as? [String: Any],
            let creator = d["IOUserClientCreator"] as? String, let pidStr = creator.split(separator: ",").first?.split(separator: " ").last,
            let pid = pid_t(pidStr), pids.contains(pid), let usage = d["AppUsage"] as? [[String: Any]] else { continue }
      for u in usage { total += (u["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0 }
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
})();
"""

final class AppWindow: NSObject, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
  func webViewWebContentProcessDidTerminate(_ w: WKWebView) { log("[ui] web process ended; reloading"); w.load(URLRequest(url: URL(string: "tidewall://app/ui/index.html")!)) }
  weak var app: App?
  var window: NSWindow?, web: WKWebView?, usageTimer: Timer?
  init(app: App) { self.app = app }

  func show(page: String? = nil) {
    NSApp.setActivationPolicy(.regular)
    if window == nil { build() }
    window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    if let page { js("{\"t\":\"show\",\"page\":\"\(page)\"}") }
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
    wv.load(URLRequest(url: URL(string: "tidewall://app/ui/index.html")!))
    window = w; web = wv
    _ = app?.usage.sample()
    usageTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.pushUsage() }
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
  func toast(_ s: String) { if let d = try? JSONSerialization.data(withJSONObject: ["t": "toast", "s": s]), let j = String(data: d, encoding: .utf8) { js(j) } }
  func js(_ json: String) { web?.evaluateJavaScript("window.tw&&tw.receive(\(json));null", completionHandler: nil) }
  /// what the wallpaper costs, and (apart) what this window costs while it's open
  func pushUsage() {
    guard let u = app?.usage.sample() else { return }
    let ui = pid_t(web.map(webPid) ?? -1), uc = u.cpuBy[ui] ?? 0, um = u.memBy[ui] ?? 0
    js(String(format: "{\"t\":\"usage\",\"cpu\":%.2f,\"gpu\":%.2f,\"mem\":%.1f,\"winCpu\":%.2f,\"winMem\":%.1f}", max(0, u.cpu - uc), u.gpu, max(0, u.memMB - um), uc, um))
  }
  /// the main display and what's on it now: the preview shows your own desktop
  func desktopJSON() -> String {
    guard let app, let scr = NSScreen.screens.first else { return "null" }
    let f = scr.cgFrame
    var wins: [[String: Any]] = []
    for (i, r) in app.lastRects.enumerated() where r.intersects(f) {
      let owner = i < app.lastOwners.count ? app.lastOwners[i] : ""
      if ["Tidewall", "tidewall", "WindowManager", "Dock"].contains(owner) { continue }   // this window; Stage Manager's app-icon badges
      wins.append(["x": r.minX - f.minX, "y": r.minY - f.minY, "w": r.width, "h": r.height, "name": owner,
                   "sm": Tracker.stageRects.contains("\(r)"), "widget": owner == "Notification Centre" || owner == "WidgetKit Simulator"])
    }
    let d: [String: Any] = ["w": f.width, "h": f.height, "windows": wins]
    return (try? JSONSerialization.data(withJSONObject: d)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
  }
  func pushState() {
    guard let app, web != nil else { return }
    let ds = NSScreen.screens.map { s -> [String: Any] in let f = s.cgFrame, id = s.displayID
      return ["id": Int(id), "name": s.localizedName, "x": f.minX, "y": f.minY, "w": f.width, "h": f.height, "theme": Cfg.theme(for: id),
              "own": Cfg.d.string(forKey: "theme.display.\(id)") != nil, "main": s == NSScreen.screens.first] }
    var vars: [String: String] = [:]; for (t, _) in Cfg.themes { if let v = Cfg.variant(t) { vars[t] = v } }
    let st: [String: Any] = ["t": "state", "current": Cfg.theme, "displays": ds, "variants": vars, "seed": Cfg.seed, "version": Cfg.version, "siteQuery": Cfg.siteQuery,
      "settings": ["login": LoginItem.enabled, "restWhenIdle": Cfg.restWhenIdle, "paused": app.userPaused, "fps": Cfg.fps, "margin": Cfg.margin]]
    if let d = try? JSONSerialization.data(withJSONObject: st), let s = String(data: d, encoding: .utf8) { js(s) }
  }
  func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
    if m.name == "host" { let s = "\(m.body)"; if s.hasPrefix("JSERR") { log("[preview] \(s)") }; return }
    guard m.frameInfo.isMainFrame, let app, let str = m.body as? String, let d = str.data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let t = o["t"] as? String else { return }
    switch t {
    case "hello": pushState(); pushUsage(); js("{\"t\":\"desktop\",\"d\":\(desktopJSON())}"); return
    case "desktop": js("{\"t\":\"desktop\",\"d\":\(desktopJSON())}"); return
    case "open": if let s = o["url"] as? String, let url = URL(string: s), ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }; return
    case "log": log("[ui] \(o["s"] as? String ?? "")"); return
    case "apply": if let id = o["theme"] as? String, Cfg.themes.contains(where: { $0.0 == id }) { Cfg.clearDisplayThemes(); Cfg.theme = id; app.reloadAll() }
    case "applyDisplay":
      let th = o["theme"] as? String
      if let did = o["display"] as? Int, let id = CGDirectDisplayID(exactly: did), NSScreen.screens.contains(where: { $0.displayID == id }),
         th == nil || Cfg.themes.contains(where: { $0.0 == th }) { Cfg.setTheme(th, for: id); app.reloadWall(id) }
    case "variant": if let th = o["theme"] as? String, let v = o["id"] as? String {
        Cfg.setVariant(th, v); for s in NSScreen.screens where Cfg.theme(for: s.displayID) == th { app.reloadWall(s.displayID) } }
    case "set":
      let v = o["value"]
      switch o["key"] as? String ?? "" {
      case "login": if let why = LoginItem.set(v as? Bool ?? false) { toast(why) }
      case "restWhenIdle": Cfg.restWhenIdle = v as? Bool ?? true
      case "paused": app.userPaused = v as? Bool ?? false; app.dispatch(live: false)
      case "fps": Cfg.fps = (v as? NSNumber)?.doubleValue ?? 0; app.reloadAll()
      case "margin": Cfg.margin = (v as? NSNumber)?.doubleValue ?? 140; app.tracker.forceResend()
      default: break }
    case "reload": app.reloadAll()
    case "quit": NSApp.terminate(nil)
    default: break
    }
    pushState(); app.buildMenu()
  }
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
    let lines = first ? ["CPU     measuring…", "GPU     measuring…", "Memory  measuring…"]
      : [String(format: "CPU     %.1f%%", s.cpu), String(format: "GPU     %.1f%%", s.gpu), String(format: "Memory  %.0f MB  (%d processes)", s.memMB, s.procs)]
    for (i, l) in lines.enumerated() { menu.item(withTag: 900 + i)?.attributedTitle = NSAttributedString(string: l, attributes: [.font: mono]) }
  }
  var walls: [CGDirectDisplayID: Wallpaper] = [:]
  let tracker = Tracker()
  var status: NSStatusItem!
  var userPaused = false, locked = false, displaysAsleep = false, awayTimer: Timer?, releasedAway = false, idleRest = false, idleTimer: Timer?, testPauseArmed = false
  var asleep: Bool { locked || displaysAsleep }
  var lastRects: [CGRect] = []
  var lastOwners: [String] = []
  weak var cursorWall: Wallpaper?
  lazy var appWindow = AppWindow(app: self)
  func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows f: Bool) -> Bool { if !benchMode { appWindow.show() }; return false }

  func applicationDidFinishLaunching(_ n: Notification) {
    if let a = argValue("--appearance") { NSApp.appearance = NSAppearance(named: a == "light" ? .aqua : .darkAqua) }
    if args.contains("--ui-only") {           // dev: just the app window (no wallpapers), to work on the interface
      tracker.onUpdate = { [weak self] r, _ in self?.lastRects = r; self?.lastOwners = self?.tracker.owners ?? [] }; tracker.start()
      buildMainMenu { [weak self] in self?.appWindow.show(page: "about") }; appWindow.show()
      if let c = argValue("--closetest"), let t = Double(c) { DispatchQueue.main.asyncAfter(deadline: .now() + t) { self.appWindow.window?.performClose(nil) } }   // dev: is it all freed?
      if args.contains("--demo") { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.appWindow.js("{\"t\":\"demo\"}") } }   // dev: the promo video's app-window shot
      if let m = argValue("--mode") { DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.appWindow.js("{\"t\":\"mode\",\"m\":\"\(m == "sample" ? "sample" : "mine")\"}") } }   // dev
      if let t = argValue("--select") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.appWindow.js("{\"t\":\"select\",\"id\":\"\(t)\"}") } }   // dev
      if let p = argValue("--page") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.appWindow.show(page: p) } }
      return }
    SimInput.start()
    buildWalls()
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
      let limit = Double(argValue("--idletest") ?? "180") ?? 180
      idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
        guard let self else { return }
        let quiet = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let rest = Cfg.restWhenIdle && quiet > limit
        if rest != self.idleRest { self.idleRest = rest; log(rest ? "idle: resting" : "input: awake"); self.dispatch(live: false) }
      }
    }
    if let t = argValue("--testpause"), let a = Double(t), !testPauseArmed {   /* bench: pause at a, resume at a + 8 */
      testPauseArmed = true
      DispatchQueue.main.asyncAfter(deadline: .now() + a) { self.userPaused = true; self.dispatch(live: false) }
      DispatchQueue.main.asyncAfter(deadline: .now() + a + 8) { self.userPaused = false; self.dispatch(live: false) } }
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.buildWalls() }
    let wnc = NSWorkspace.shared.notificationCenter
    wnc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.displaysAsleep = true; self?.dispatch(live: false) }
    wnc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.displaysAsleep = false; self?.dispatch(live: false) }
    let dnc = DistributedNotificationCenter.default()
    dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.locked = true; self?.dispatch(live: false) }
    dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.locked = false; self?.dispatch(live: false) }
    if !benchMode {
      LoginItem.refresh()
      DistributedNotificationCenter.default().addObserver(forName: .init("app.tidewall.show"), object: nil, queue: .main) { [weak self] _ in self?.appWindow.show() }
      buildMenu()
      if Bundle.main.bundleIdentifier == nil, let i = NSImage(contentsOf: themesRoot.appendingPathComponent("ui/icon.png")) { NSApp.applicationIconImage = i }
      buildMainMenu { [weak self] in self?.appWindow.show(page: "about") }
      // opened by hand (not at login): show the window
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
    if releasedAway { return }                                     // away: the pages come back when you do
    let ids = Set(NSScreen.screens.map { $0.displayID })
    for (id, w) in walls where !ids.contains(id) { w.close(); walls[id] = nil }
    for s in NSScreen.screens where (!benchMode || s == NSScreen.screens.first) && !dormant.contains(s.displayID) {
      if let w = walls[s.displayID] { w.cgFrame = s.cgFrame; w.window.setFrame(s.frame, display: true); w.sendDesk() }
      else { let id = s.displayID, still = stills[id]; let w = Wallpaper(screen: s, hidden: still != nil); walls[id] = w
        if let still { w.onShown = { [weak self] in still.close(); if self?.stills[id] === still { self?.stills[id] = nil } }
          DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in if self?.stills[id] === still { w.window.alphaValue = 1; still.close(); self?.stills[id] = nil } } } }   // never leave a stale still up
    }
    tracker.forceResend()
  }

  func reloadAll() { walls.values.forEach { $0.close() }; walls = [:]; buildWalls() }
  func reloadWall(_ id: CGDirectDisplayID) { walls[id]?.close(); walls[id] = nil; buildWalls() }

  var coveredSince: [CGDirectDisplayID: Double] = [:], dormant: Set<CGDirectDisplayID> = []
  func dispatch(live: Bool) {
    let now = ProcessInfo.processInfo.systemUptime
    for s in NSScreen.screens where !benchMode && !live {
      let id = s.displayID, frame = s.cgFrame
      let covered = !live && uncoveredArea(frame, lastRects) < 1
      if covered { if coveredSince[id] == nil { coveredSince[id] = now } } else { coveredSince[id] = nil }
      if covered, let since = coveredSince[id], now - since > 15, let w = walls[id] {          // nobody can see it: free it
        w.close(); walls[id] = nil; dormant.insert(id); log("screen \(id) fully covered: released its page")
      } else if !covered, dormant.contains(id), !releasedAway {                                               // a sliver is visible again
        dormant.remove(id); walls[id] = Wallpaper(screen: s); log("screen \(id) uncovered: page restored")
      }
    }
    scheduleCoverCheck()
    Tracker.idle = userPaused || asleep || idleRest
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
      let idx = lastRects.indices.filter { lastRects[$0].intersects(w.cgFrame) }
      let mine = idx.map { lastRects[$0] }, names = idx.map { $0 < lastOwners.count ? lastOwners[$0] : "" }
      // never pause while windows are moving (a sliver of the town is still on show and must keep up)
      let pause = userPaused || asleep || idleRest || (!live && uncoveredArea(w.cgFrame, mine) < 1)
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
    for (i, title) in ["CPU  –", "GPU  –", "Memory  –"].enumerated() {
      let it = NSMenuItem(title: title, action: nil, keyEquivalent: ""); it.isEnabled = false; it.tag = 900 + i
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
    sub("Theme", Cfg.themes.map { (id, label) in (label, Cfg.theme == id, { Cfg.clearDisplayThemes(); Cfg.theme = id; self.reloadAll(); self.buildMenu(); self.appWindow.pushState() }) })
    m.addItem(.separator())
    let ri = ClosureItem("Rest when idle") { Cfg.restWhenIdle.toggle(); self.buildMenu(); self.appWindow.pushState() }; ri.state = Cfg.restWhenIdle ? .on : .off
    let p = ClosureItem("Pause") { self.userPaused.toggle(); self.dispatch(live: false); self.buildMenu(); self.appWindow.pushState() }
    p.state = userPaused ? .on : .off; m.addItem(p); m.addItem(ri)
    let li = ClosureItem("Open at login") { if let why = LoginItem.set(!LoginItem.enabled) { let a = NSAlert(); a.messageText = why; a.runModal() }; self.buildMenu(); self.appWindow.pushState() }
    li.state = LoginItem.enabled ? .on : .off; m.addItem(li)
    m.addItem(.separator())
    m.addItem(ClosureItem("Quit Tidewall") { NSApp.terminate(nil) })
    status.menu = m
  }
}

final class ClosureItem: NSMenuItem {
  let f: () -> Void
  init(_ t: String, _ f: @escaping () -> Void) { self.f = f; super.init(title: t, action: #selector(run), keyEquivalent: ""); target = self }
  required init(coder: NSCoder) { fatalError() }
  @objc func run() { f() }
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
    if let name = argValue("--layout"), let l = layouts[name] { rects0 = l.map { $0.0 }; owners0 = l.map { $0.1 }; stage0 = l.filter { $0.2 }.map { $0.0 } }
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
        w.web.evaluateJavaScript("[(window.__prof?('JSms/frame='+(__prof.ms/Math.max(1,__prof.n)).toFixed(2)+' frames/s='+(__prof.n/((performance.now()-__prof.t0)/1000)).toFixed(1)):''),(typeof window.__dbg==='function'?__dbg():''), (typeof icons!=='undefined'?'icon0='+JSON.stringify(icons[0]&&{x:icons[0].x|0,y:icons[0].y|0,w:icons[0].w|0,h:icons[0].h|0})+' s@c='+(typeof curS==='function'&&icons[0]?curS(icons[0].x+icons[0].w/2,icons[0].y+icons[0].h/2).toFixed(0):'-')+' frames='+(typeof frameN!=='undefined'?frameN:'-')+' icons='+icons.length+' mix='+(typeof curMix!=='undefined'?curMix.toFixed(2):'-')+' from/to='+(typeof fromI!=='undefined'?fromI+'/'+toI:'-')+' morphT0='+(typeof morphT0!=='undefined'?(morphT0|0):'-')+' FB='+(typeof FB!=='undefined'&&!!FB)+' iconsSeen='+(typeof iconsSeen!=='undefined'?iconsSeen:'-'):''), devicePixelRatio, cv.width+'x'+cv.height, cv._scale, P.quality, Math.round(fpsEMA), fieldMs.toFixed(1), (window.__gl?window.__gl.drawingBufferWidth:0)+'x'+(window.__gl?window.__gl.drawingBufferHeight:0), paused].join(' ')") { r, _ in
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
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { tm in
          let t = ProcessInfo.processInfo.systemUptime - t0, a = 0.35, b = dur - 0.7
          let u = max(0, min(1, (t - a) / (b - a))), e = u * u * u * (u * (u * 6 - 15) + 10)       // smootherstep
          app.lastRects[0] = CGRect(x: from.minX + mv[0] * e, y: from.minY + mv[1] * e, width: from.width, height: from.height)
          app.dispatch(live: t > a && t < b)
          if t > dur { tm.invalidate(); app.dispatch(live: false) }
        }
        func shoot() {
          let t = ProcessInfo.processInfo.systemUptime - t0
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
        guard let w = app.walls.values.first(where: { $0.cgFrame.origin == .zero }) else { return }
        w.web.takeSnapshot(with: nil) { img, _ in
          if let img, let r = NSBitmapImageRep(data: img.tiffRepresentation!) { try? r.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: shot)); log("snapshot -> \(shot)") }
        }
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + secs) { NSApp.terminate(nil) }
  }
}

// one Tidewall at a time: opening a second copy shows the running one's window instead
if !benchMode && !args.contains("--ui-only"), let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
  DistributedNotificationCenter.default().postNotificationName(.init("app.tidewall.show"), object: nil, userInfo: nil, deliverImmediately: true)
  exit(0)
}
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

extension NSFont { func withWeight(_ w: NSFont.Weight) -> NSFont { NSFont.systemFont(ofSize: pointSize, weight: w) } }

/// a web view's content process id (private, guarded: -1 if it ever goes away)
func webPid(_ w: WKWebView) -> Int { w.responds(to: NSSelectorFromString("_webProcessIdentifier")) ? (w.value(forKey: "_webProcessIdentifier") as? Int) ?? -1 : -1 }
