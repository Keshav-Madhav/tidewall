import Foundation
import CryptoKit

/// The checks a downloaded file, or a copy of the app unpacked from one, must pass before it may replace this copy.
enum BundleCheck {
  /// Why `file` isn't the expected download (nil = it is).
  static func mismatch(_ file: URL, size: Int, sha: String) -> String? {
    guard (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int == size else { return "size mismatch" }
    guard let digest = sha256(of: file) else { return "can't read the download" }
    guard digest == sha.lowercased() else { return "checksum mismatch" }
    return nil
  }

  static func sha256(of file: URL) -> String? {
    guard let handle = FileHandle(forReadingAtPath: file.path) else { return nil }
    var hasher = SHA256()
    while case let chunk = handle.readData(ofLength: 1 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    try? handle.close()
    return hasher.finalize().hex
  }

  static func isTidewall(_ app: URL, version: String) -> Bool {
    guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return false }
    return info["CFBundleIdentifier"] as? String == "app.tidewall" && info["CFBundleShortVersionString"] as? String == version
  }

  /// The bundle's code-directory hash, if its signature (which seals every file in it) verifies; nil if it doesn't.
  static func codeHash(_ app: URL) -> String? {
    guard runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).status == 0 else { return nil }
    // The Apple-silicon slice's hash on any Mac: the release records that one, and an Intel Mac's own never matched.
    let details = runTool("/usr/bin/codesign", ["-dv", "--verbose=4", "--arch", "arm64", app.path]).output
    return details.split(separator: "\n").first { $0.hasPrefix("CDHash=") }.map(String.init)
  }
}

extension SHA256.Digest {
  var hex: String { map { String(format: "%02x", $0) }.joined() }
}
