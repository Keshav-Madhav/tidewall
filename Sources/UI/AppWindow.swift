import Cocoa
import WebKit

/// Runs in every frame of the app window. The preview frame (a real theme page) gets the host surface it expects, but
/// its messages go to the page around it, which plays host: a pretend desktop with windows you can drag.
private let frameShim = """
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

/// The app window: themes with a live preview, the displays and the settings, as an HTML page (themes/ui) in a native,
/// translucent window. Its bridge to the page is in AppWindow+Bridge.swift.
final class AppWindow: NSObject, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
  private static let pageURL = URL(string: "tidewall://app/ui/index.html")!

  weak var app: App?
  var window: NSWindow?
  var web: WKWebView?
  var pendingPage: String?
  private var usageTimer: Timer?

  init(app: App) { self.app = app }

  func show(page: String? = nil) {
    if !benchBehind { NSApp.setActivationPolicy(.regular) }
    let fresh = window == nil
    if fresh { build() }
    if benchBehind, let w = window {
      keepBehind(w)
    } else {
      window?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
    guard let page else { return }
    if fresh {
      pendingPage = page
    } else {
      showPage(page)
    }
  }

  /// Tests drive the window unseen (dev): behind the wallpaper, never key or active, with WebKit's occlusion detection
  /// off (a private call) so the page still renders.
  private func keepBehind(_ w: NSWindow) {
    w.level = behindLevel
    w.orderBack(nil)
    let setDetection = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
    guard let wv = web, wv.responds(to: setDetection),
          let imp = class_getMethodImplementation(type(of: wv), setDetection) else { return }
    typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool) -> Void
    unsafeBitCast(imp, to: SetEnabled.self)(wv, setDetection, false)
  }

  private func build() {
    let configuration = webConfiguration()
    let w = makeWindow()
    let backdrop = NSVisualEffectView()
    backdrop.material = .sidebar
    backdrop.blendingMode = .behindWindow
    backdrop.state = .followsWindowActiveState
    w.contentView = backdrop
    let wv = WKWebView(frame: backdrop.bounds, configuration: configuration)
    wv.autoresizingMask = [.width, .height]
    wv.navigationDelegate = self
    wv.setValue(false, forKey: "drawsBackground")
    backdrop.addSubview(wv)
    addTitlebarDragStrips(to: backdrop)
    wv.load(URLRequest(url: Self.pageURL))
    window = w
    web = wv
    _ = app?.usage.sample()
    startUsageTimer()
  }

  /// A web process of its own: the preview can never stall the wallpapers, and it ends with the window.
  private func webConfiguration() -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(SchemeHandler(), forURLScheme: "tidewall")
    let ucc = configuration.userContentController
    ucc.addUserScript(WKUserScript(source: frameShim, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    ucc.add(WeakHandler(self), name: "ui")
    ucc.add(WeakHandler(self), name: "host")
    return configuration
  }

  private func makeWindow() -> NSWindow {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                     backing: .buffered, defer: false)
    w.title = "Tidewall"
    w.titlebarAppearsTransparent = true
    w.titleVisibility = .hidden
    w.toolbar = NSToolbar(identifier: "tidewall")
    w.toolbarStyle = .unified
    w.minSize = NSSize(width: 960, height: 640)
    w.isReleasedWhenClosed = false
    w.delegate = self
    w.center()
    w.setFrameAutosaveName("TidewallWindow")
    return w
  }

  /// The page fills the window, title-bar area included, and WebKit ignores -webkit-app-region (an Electron-only
  /// feature): without these strips the window can't be dragged. 28 pt across the top, and the sidebar's empty top.
  private func addTitlebarDragStrips(to view: NSView) {
    let width = view.bounds.width, height = view.bounds.height
    let strips: [(NSRect, NSView.AutoresizingMask)] = [
      (NSRect(x: 0, y: height - 28, width: width, height: 28), [.width, .minYMargin]),
      (NSRect(x: 0, y: height - 52, width: 222, height: 52), [.minYMargin]),
    ]
    for (frame, resizing) in strips {
      let strip = TitlebarDrag(frame: frame)
      strip.autoresizingMask = resizing
      view.addSubview(strip)
    }
  }

  private func startUsageTimer() {
    usageTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      guard let w = self?.window, w.occlusionState.contains(.visible), !w.isMiniaturized else { return }
      self?.pushUsage()
    }
  }

  /// The page, its live preview and all their memory go with the window.
  func windowWillClose(_ n: Notification) {
    usageTimer?.invalidate()
    usageTimer = nil
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      web?.configuration.userContentController.removeAllScriptMessageHandlers()
      web?.removeFromSuperview()
      web = nil
      window = nil
      NSApp.setActivationPolicy(.accessory)
      if args.contains("--ui-only") && !args.contains("--closetest") { NSApp.terminate(nil) }
    }
  }

  func webViewWebContentProcessDidTerminate(_ w: WKWebView) {
    log("[ui] web process ended; reloading")
    w.load(URLRequest(url: Self.pageURL))
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
      default: w.performZoom(nil)
      }
      return
    }
    w.performDrag(with: e)
  }
}
