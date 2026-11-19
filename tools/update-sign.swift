// Tidewall's update signing (Ed25519, CryptoKit). CI signs releases with the main private key; the app ships the public
// halves of that key and of an offline backup key (Updater.publicKeys) and installs only updates that verify against
// one of them. This is what keeps updates safe without an Apple Developer ID.
//
//   swift tools/update-sign.swift keygen                              → prints a new key pair (do this ONCE, ever)
//   TIDEWALL_UPDATE_KEY=<base64 private> swift tools/update-sign.swift sign <zip> <version> <url> <notes-file>
//                       [<cdhash> [<patch-zip> <patch-from-version> <patch-url>]]   → prints update.json
//   swift tools/update-sign.swift verify <zip> <update.json> <base64 public> [<patch-zip>]   → checks a signed release
//
// With a cdhash (the release app's code-signature hash) a second signature (signature2) also covers it and the patch:
// only the files that changed since the previous release, which the app lays over a clone of itself and accepts only
// if the result has exactly this cdhash. Copies older than 1.2.2 ignore both and fetch the whole zip.
//
// The signature covers every field the app acts on (see message()): the zip's SHA-256 and size, the version, the
// minimum macOS and the notes. Changing any of them, or the zip, breaks it. The URL isn't signed: a different URL
// just fetches a file whose hash won't match.
import CryptoKit
import Foundation

func die(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }
func sha256(_ path: String) -> String {
  guard let h = FileHandle(forReadingAtPath: path) else { die("can't read \(path)") }
  var hasher = SHA256()
  while case let d = h.readData(ofLength: 1 << 20), !d.isEmpty { hasher.update(data: d) }
  return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
func message(_ version: String, _ sha: String, _ size: Int, _ minOS: String, _ notes: String) -> Data {
  let n = SHA256.hash(data: Data(notes.utf8)).map { String(format: "%02x", $0) }.joined()
  return Data("tidewall-update-v1\n\(version)\n\(sha)\n\(size)\n\(minOS)\n\(n)".utf8)
}
func message2(_ version: String, _ sha: String, _ size: Int, _ minOS: String, _ notes: String, _ cdhash: String, _ pFrom: String, _ pSha: String, _ pSize: Int) -> Data {
  let n = SHA256.hash(data: Data(notes.utf8)).map { String(format: "%02x", $0) }.joined()
  return Data("tidewall-update-v2\n\(version)\n\(sha)\n\(size)\n\(minOS)\n\(n)\n\(cdhash.lowercased())\n\(pFrom)\n\(pSha)\n\(pSize)".utf8)
}
let a = CommandLine.arguments
switch a.count > 1 ? a[1] : "" {
case "keygen":
  let k = Curve25519.Signing.PrivateKey()
  print("private (secret!):", k.rawRepresentation.base64EncodedString())
  print("public:           ", k.publicKey.rawRepresentation.base64EncodedString())
case "sign":
  guard a.count == 6 || a.count == 7 || a.count == 10 else { die("usage: sign <zip> <version> <url> <notes-file> [<cdhash> [<patch-zip> <patch-from> <patch-url>]]") }
  guard let b64 = ProcessInfo.processInfo.environment["TIDEWALL_UPDATE_KEY"], let raw = Data(base64Encoded: b64.trimmingCharacters(in: .whitespacesAndNewlines)),
        let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { die("TIDEWALL_UPDATE_KEY missing or invalid") }
  let (zip, version, url) = (a[2], a[3], a[4]), sha = sha256(zip)
  let size = (try? FileManager.default.attributesOfItem(atPath: zip)[.size] as? Int) ?? 0
  let notes = ((try? String(contentsOfFile: a[5], encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines), minOS = "14.0"
  let sig = try! key.signature(for: message(version, sha, size, minOS, notes)).base64EncodedString()
  var o: [String: Any] = ["version": version, "url": url, "sha256": sha, "size": size, "signature": sig, "minimumSystemVersion": minOS,
                          "notes": notes, "published": ISO8601DateFormatter().string(from: Date())]
  if a.count >= 7 {
    let cd = a[6].lowercased(); guard cd.count >= 40, cd.allSatisfy({ $0.isHexDigit }) else { die("bad cdhash") }
    var pFrom = "-", pSha = "-", pSize = 0
    if a.count == 10 {
      pSha = sha256(a[7]); pSize = (try? FileManager.default.attributesOfItem(atPath: a[7])[.size] as? Int) ?? 0; pFrom = a[8]
      o["patch"] = ["from": pFrom, "url": a[9], "sha256": pSha, "size": pSize]
    }
    o["cdhash"] = cd
    o["signature2"] = try! key.signature(for: message2(version, sha, size, minOS, notes, cd, pFrom, pSha, pSize)).base64EncodedString()
  }
  print(String(data: try! JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
case "verify":
  guard a.count == 5 || a.count == 6, let j = try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: a[3]))) as? [String: Any],
        let version = j["version"] as? String, let sha = j["sha256"] as? String, let sig = (j["signature"] as? String).flatMap({ Data(base64Encoded: $0) }),
        let size = (j["size"] as? NSNumber)?.intValue, let minOS = j["minimumSystemVersion"] as? String, let notes = j["notes"] as? String,
        let pubRaw = Data(base64Encoded: a[4]), let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: pubRaw) else { die("usage: verify <zip> <update.json> <public>") }
  guard sha256(a[2]) == sha else { die("sha256 mismatch") }
  guard (try? FileManager.default.attributesOfItem(atPath: a[2])[.size] as? Int) == size else { die("size mismatch") }
  guard pub.isValidSignature(sig, for: message(version, sha, size, minOS, notes)) else { die("BAD signature") }
  if let s2 = (j["signature2"] as? String).flatMap({ Data(base64Encoded: $0) }), let cd = j["cdhash"] as? String {
    let p = j["patch"] as? [String: Any], pf = p?["from"] as? String ?? "-", ps = p?["sha256"] as? String ?? "-", pz = (p?["size"] as? NSNumber)?.intValue ?? 0
    guard pub.isValidSignature(s2, for: message2(version, sha, size, minOS, notes, cd, pf, ps, pz)) else { die("BAD second signature") }
    if p != nil {
      guard a.count == 6 else { die("this release has a patch: pass the patch zip to verify it") }
      guard sha256(a[5]) == ps, (try? FileManager.default.attributesOfItem(atPath: a[5])[.size] as? Int) == pz else { die("patch sha256/size mismatch") }
    }
    print("ok: \(version) \(sha) cdhash \(cd)\(p != nil ? " patch from \(pf) (\(pz) bytes)" : "")")
  } else { print("ok: \(version) \(sha)") }
default: die("usage: keygen | sign | verify")
}
