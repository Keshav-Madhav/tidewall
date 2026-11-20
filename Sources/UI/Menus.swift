import Cocoa

/// The menu-bar glyph: a window with a tide curling inside it, the app icon's idea as a template image so it follows the
/// menu bar's appearance.
func menuGlyph() -> NSImage {
  let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
    NSColor.black.set()
    let frame = NSBezierPath(roundedRect: NSRect(x: 1.6, y: 2.6, width: 14.8, height: 12.8), xRadius: 3.5, yRadius: 3.5)
    frame.lineWidth = 1.5
    frame.stroke()
    NSGraphicsContext.current?.saveGraphicsState()
    frame.addClip()
    tidePath().fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    return true
  }
  image.isTemplate = true
  return image
}

/// The wave, from the right edge: its crest, curling over and in, then the trough, closed along the bottom.
private func tidePath() -> NSBezierPath {
  let p = NSBezierPath()
  p.move(to: NSPoint(x: 18, y: 9.6))
  p.curve(to: NSPoint(x: 9.2, y: 11.6), controlPoint1: NSPoint(x: 15.4, y: 12.2), controlPoint2: NSPoint(x: 11.8, y: 12.6))
  p.curve(to: NSPoint(x: 6.4, y: 8.4), controlPoint1: NSPoint(x: 7.0, y: 11.0), controlPoint2: NSPoint(x: 5.9, y: 9.6))
  p.curve(to: NSPoint(x: 9.0, y: 8.2), controlPoint1: NSPoint(x: 6.9, y: 7.2), controlPoint2: NSPoint(x: 8.6, y: 7.2))
  p.curve(to: NSPoint(x: 7.6, y: 5.6), controlPoint1: NSPoint(x: 9.6, y: 6.9), controlPoint2: NSPoint(x: 9.0, y: 5.8))
  p.curve(to: NSPoint(x: 0, y: 6.2), controlPoint1: NSPoint(x: 5.4, y: 5.3), controlPoint2: NSPoint(x: 2.0, y: 7.4))
  p.line(to: NSPoint(x: 0, y: 0))
  p.line(to: NSPoint(x: 18, y: 0))
  p.close()
  return p
}

/// The app's own menu, shown while the window is open and Tidewall is in the Dock.
func buildMainMenu(_ open: @escaping () -> Void) {
  let appMenu = NSMenu()
  appMenu.addItem(ClosureItem("About Tidewall") { open() })
  appMenu.addItem(.separator())
  appMenu.addItem(NSMenuItem(title: "Hide Tidewall", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
  appMenu.addItem(.separator())
  appMenu.addItem(NSMenuItem(title: "Quit Tidewall", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

  let windowMenu = NSMenu(title: "Window")
  windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
  windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))

  let main = NSMenu()
  for submenu in [appMenu, windowMenu] {
    let item = NSMenuItem()
    item.submenu = submenu
    main.addItem(item)
  }
  NSApp.mainMenu = main
}

/// A menu item that runs a closure when chosen.
final class ClosureItem: NSMenuItem {
  private let handler: () -> Void

  init(_ t: String, _ handler: @escaping () -> Void) {
    self.handler = handler
    super.init(title: t, action: #selector(run), keyEquivalent: "")
    target = self
  }

  required init(coder: NSCoder) { fatalError() }

  /// Runs once the click has been handled, not inside it: many actions rebuild the very menu this item belongs to.
  @objc private func run() {
    let handler = self.handler
    DispatchQueue.main.async { handler() }
  }
}
