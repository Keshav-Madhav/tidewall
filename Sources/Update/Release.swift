import Foundation
import CryptoKit

/// A release as the update feed (update.json) describes it. Nothing in it may be acted on until `isSigned`.
struct Release {
  /// Only the files changed since `from`; the patched copy must match the release's code-signature hash exactly.
  struct Patch {
    let from: String
    let url: URL
    let sha: String
    let size: Int
  }

  let version: String
  let url: URL
  let sha: String
  let signature: Data
  let size: Int
  let minOS: String
  let notes: String

  init?(feed: [String: Any]) {
    guard let version = feed["version"] as? String,
          let urlString = feed["url"] as? String, let url = URL(string: urlString),
          let sha = feed["sha256"] as? String,
          let signature = (feed["signature"] as? String).flatMap({ Data(base64Encoded: $0) }),
          let size = (feed["size"] as? NSNumber)?.intValue,
          let minOS = feed["minimumSystemVersion"] as? String,
          let notes = feed["notes"] as? String else { return nil }
    self.version = version
    self.url = url
    self.sha = sha
    self.signature = signature
    self.size = size
    self.minOS = minOS
    self.notes = notes
  }

  // MARK: signatures (tools/update-sign.swift makes the same messages)

  /// The release signature, over every field the app acts on.
  var isSigned: Bool {
    let message = "tidewall-update-v1\n\(version)\n\(sha.lowercased())\n\(size)\n\(minOS)\n\(notesDigest)"
    return Self.trusted(signature, over: message)
  }

  /// The second signature also covers the code-signature hash and a patch ("-" and 0 for none); older copies ignore it.
  func signs(_ sig: Data, cdhash: String, patchFrom: String, patchSha: String, patchSize: Int) -> Bool {
    let message = "tidewall-update-v2\n\(version)\n\(sha.lowercased())\n\(size)\n\(minOS)\n\(notesDigest)\n\(cdhash.lowercased())\n\(patchFrom)\n\(patchSha.lowercased())\n\(patchSize)"
    return Self.trusted(sig, over: message)
  }

  private var notesDigest: String { SHA256.hash(data: Data(notes.utf8)).hex }

  private static func trusted(_ signature: Data, over message: String) -> Bool {
    let data = Data(message.utf8)
    return Updater.trustedKeys.contains { key in
      let publicKey = Data(base64Encoded: key).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
      return publicKey?.isValidSignature(signature, for: data) ?? false
    }
  }

  /// The patch from this copy's version, and the code-signature hash it must arrive at, if the feed signs one.
  func patch(in feed: [String: Any]) -> (patch: Patch, cdhash: String)? {
    latestPatch(in: feed) ?? listedPatch(in: feed)
  }

  /// The patch from the release just before this one, trusted only under the second signature.
  private func latestPatch(in feed: [String: Any]) -> (patch: Patch, cdhash: String)? {
    guard let signature2 = (feed["signature2"] as? String).flatMap({ Data(base64Encoded: $0) }),
          let cdhash = feed["cdhash"] as? String else { return nil }
    let entry = feed["patch"] as? [String: Any]
    let from = entry?["from"] as? String ?? "-"
    let sha = entry?["sha256"] as? String ?? "-"
    let size = (entry?["size"] as? NSNumber)?.intValue ?? 0
    guard signs(signature2, cdhash: cdhash, patchFrom: from, patchSha: sha, patchSize: size) else {
      log("[update] the patch information isn't signed by Tidewall; ignoring it")
      return nil
    }
    guard from == Cfg.version, let urlString = entry?["url"] as? String, let url = URL(string: urlString),
          Updater.mayDownload(url) else { return nil }
    return (Patch(from: from, url: url, sha: sha, size: size), cdhash)
  }

  /// A patch from further back (this copy skipped a release), each entry trusted only under its own signature.
  private func listedPatch(in feed: [String: Any]) -> (patch: Patch, cdhash: String)? {
    guard let list = feed["patches"] as? [[String: Any]], let cdhash = feed["cdhash"] as? String else { return nil }
    for entry in list where entry["from"] as? String == Cfg.version {
      guard let sha = entry["sha256"] as? String, let size = (entry["size"] as? NSNumber)?.intValue, size > 0,
            let signature = (entry["signature"] as? String).flatMap({ Data(base64Encoded: $0) }),
            signs(signature, cdhash: cdhash, patchFrom: Cfg.version, patchSha: sha, patchSize: size) else {
        log("[update] the patch from \(Cfg.version) isn't signed by Tidewall; ignoring it")
        continue
      }
      guard let urlString = entry["url"] as? String, let url = URL(string: urlString), Updater.mayDownload(url) else {
        continue
      }
      return (Patch(from: Cfg.version, url: url, sha: sha, size: size), cdhash)
    }
    return nil
  }
}
