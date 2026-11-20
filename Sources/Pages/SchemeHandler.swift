import Cocoa
import WebKit

/// Serves `themes/` to every web view over the private `tidewall:` scheme. Pages loaded from file:// get an opaque
/// origin, which taints any canvas they draw an image into.
final class SchemeHandler: NSObject, WKURLSchemeHandler {
  private static let mimeTypes = ["html": "text/html", "js": "text/javascript", "json": "application/json", "png": "image/png",
                                  "webp": "image/webp", "css": "text/css", "svg": "image/svg+xml", "glb": "model/gltf-binary",
                                  "wasm": "application/wasm", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                                  "bin": "application/octet-stream"]

  func webView(_ w: WKWebView, start t: WKURLSchemeTask) {
    let file = t.request.url.map { themesRoot.appendingPathComponent(String($0.path.dropFirst())).standardized }
    guard let url = t.request.url, let file, file.path.hasPrefix(themesRoot.path + "/"), let data = try? Data(contentsOf: file) else {
      t.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
      return
    }
    let mime = Self.mimeTypes[file.pathExtension.lowercased()] ?? "application/octet-stream"
    t.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
    t.didReceive(data)
    t.didFinish()
  }

  func webView(_ w: WKWebView, stop t: WKURLSchemeTask) {}
}
