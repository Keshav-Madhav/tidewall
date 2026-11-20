import Cocoa

extension NSWindow {
  /// A borderless, opaque window at desktop level, on every Space, that the pointer passes straight through.
  /// `freeSize`: one macOS doesn't shrink to fit the screen (the harness's pretend displays can be bigger than the real one).
  static func wallpaperWindow(_ rect: NSRect, freeSize: Bool = false) -> NSWindow {
    let window: NSWindow = freeSize
      ? FreeSizeWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
      : NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
    window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
    window.ignoresMouseEvents = true
    window.isOpaque = true
    window.hasShadow = false
    window.isReleasedWhenClosed = false
    return window
  }

  /// On show at desktop level; a test run behind the wallpaper keeps it below even that.
  func showAtDesktopLevel() {
    if benchBehind {
      level = behindLevel
      orderBack(nil)
    } else {
      orderFront(nil)
    }
  }
}

final class FreeSizeWindow: NSWindow {
  override func constrainFrameRect(_ r: NSRect, to s: NSScreen?) -> NSRect { r }
}

/// What a screen shows while its page is let go: the last frame as a still picture (a few MB, no web process at all).
final class StillWall {
  let window: NSWindow

  init(frame: NSRect, image: NSImage) {
    window = .wallpaperWindow(frame)
    // one bitmap handed straight to the layer: an image view would keep extra copies of the picture
    let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
    view.wantsLayer = true
    var r = NSRect(origin: .zero, size: image.size)
    view.layer?.contents = image.cgImage(forProposedRect: &r, context: nil, hints: nil)
    view.layer?.contentsGravity = .resizeAspectFill
    window.contentView = view
    window.setFrame(frame, display: true)
    window.showAtDesktopLevel()
  }

  func close() {
    window.orderOut(nil)
    window.close()
  }
}
