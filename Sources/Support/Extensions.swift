import Cocoa
import WebKit

extension NSFont {
  func withWeight(_ w: NSFont.Weight) -> NSFont { NSFont.systemFont(ofSize: pointSize, weight: w) }
}

extension NSImage {
  @discardableResult
  func writePNG(to path: String) -> Bool {
    guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
  }
}

/// A web view's content process id (a private property, so guarded: -1 if it ever goes away).
func webPid(_ w: WKWebView) -> Int {
  guard w.responds(to: NSSelectorFromString("_webProcessIdentifier")) else { return -1 }
  return (w.value(forKey: "_webProcessIdentifier") as? Int) ?? -1
}
