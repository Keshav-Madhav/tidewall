// Tidewall's update signing (Ed25519, CryptoKit). CI signs releases with the main private key; the app ships the public
// halves of that key and of an offline backup key (Updater.publicKeys) and installs only updates that verify against
// one of them. This is what keeps updates safe without an Apple Developer ID.
//
//   swift tools/update-sign.swift keygen                              → prints a new key pair (do this ONCE, ever)
//   TIDEWALL_UPDATE_KEY=<base64 private> swift tools/update-sign.swift sign <zip> <version> <url> <notes-file>
//                       [<cdhash> [<patch-zip> <patch-from-version> <patch-url>]...]   → prints update.json
//   swift tools/update-sign.swift verify <zip> <update.json> <base64 public> [<patch-zip>...]   → checks a signed release
//
// With a cdhash (the release app's code-signature hash) a second signature (signature2) also covers it and the patch:
// only the files that changed since the previous release, which the app lays over a clone of itself and accepts only
// if the result has exactly this cdhash. Copies older than 1.2.2 ignore both and fetch the whole zip.
// Several patches (newest previous version first): the first is "patch" under signature2, as before; all of them are
// also in "patches", each with its own signature over the same v2 message with its own from/sha/size, so a copy on any
// of those versions (1.2.6 and later read the list) takes the small download. Patch zips verify in the same order.
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
  guard a.count == 6 || (a.count >= 7 && (a.count - 7) % 3 == 0) else { die("usage: sign <zip> <version> <url> <notes-file> [<cdhash> [<patch-zip> <patch-from> <patch-url>]...]") }
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
    var pFrom = "-", pSha = "-", pSize = 0, list: [[String: Any]] = []
    for i in stride(from: 7, to: a.count, by: 3) {
      let s = sha256(a[i]), z = (try? FileManager.default.attributesOfItem(atPath: a[i])[.size] as? Int) ?? 0, f = a[i + 1]
      guard z > 0, !list.contains(where: { $0["from"] as? String == f }) else { die("patch \(a[i]): empty, or a second patch from \(f)") }
      if list.isEmpty { pFrom = f; pSha = s; pSize = z; o["patch"] = ["from": f, "url": a[i + 2], "sha256": s, "size": z] }
      list.append(["from": f, "url": a[i + 2], "sha256": s, "size": z,
                   "signature": try! key.signature(for: message2(version, sha, size, minOS, notes, cd, f, s, z)).base64EncodedString()])
    }
    if !list.isEmpty { o["patches"] = list }
    o["cdhash"] = cd
    o["signature2"] = try! key.signature(for: message2(version, sha, size, minOS, notes, cd, pFrom, pSha, pSize)).base64EncodedString()
  }
  print(String(data: try! JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
case "verify":
  guard a.count >= 5, let j = try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: a[3]))) as? [String: Any],
        let version = j["version"] as? String, let sha = j["sha256"] as? String, let sig = (j["signature"] as? String).flatMap({ Data(base64Encoded: $0) }),
        let size = (j["size"] as? NSNumber)?.intValue, let minOS = j["minimumSystemVersion"] as? String, let notes = j["notes"] as? String,
        let pubRaw = Data(base64Encoded: a[4]), let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: pubRaw) else { die("usage: verify <zip> <update.json> <public>") }
  guard sha256(a[2]) == sha else { die("sha256 mismatch") }
  guard (try? FileManager.default.attributesOfItem(atPath: a[2])[.size] as? Int) == size else { die("size mismatch") }
  guard pub.isValidSignature(sig, for: message(version, sha, size, minOS, notes)) else { die("BAD signature") }
  if let s2 = (j["signature2"] as? String).flatMap({ Data(base64Encoded: $0) }), let cd = j["cdhash"] as? String {
    let p = j["patch"] as? [String: Any], pf = p?["from"] as? String ?? "-", ps = p?["sha256"] as? String ?? "-", pz = (p?["size"] as? NSNumber)?.intValue ?? 0
    guard pub.isValidSignature(s2, for: message2(version, sha, size, minOS, notes, cd, pf, ps, pz)) else { die("BAD second signature") }
    let list = j["patches"] as? [[String: Any]] ?? (p.map { [$0] } ?? []), zips = Array(a.dropFirst(5))
    guard zips.count == list.count else { die("this release has \(list.count) patch(es): pass their zips, in order, to verify them") }
    if let p { guard list.first?["from"] as? String == pf, list.first?["sha256"] as? String == ps else { die("\"patch\" isn't the first of \"patches\"") }; _ = p }
    var from: [String] = []
    for (e, z) in zip(list, zips) {
      guard let f = e["from"] as? String, let s = e["sha256"] as? String, let n = (e["size"] as? NSNumber)?.intValue else { die("a patch entry is incomplete") }
      guard sha256(z) == s, (try? FileManager.default.attributesOfItem(atPath: z)[.size] as? Int) == n else { die("patch from \(f): sha256/size mismatch") }
      if j["patches"] != nil {
        guard let es = (e["signature"] as? String).flatMap({ Data(base64Encoded: $0) }), pub.isValidSignature(es, for: message2(version, sha, size, minOS, notes, cd, f, s, n)) else { die("BAD signature on the patch from \(f)") }
      }
      from.append("\(f) (\(n) bytes)")
    }
    print("ok: \(version) \(sha) cdhash \(cd)\(from.isEmpty ? "" : " patches from " + from.joined(separator: ", "))")
  } else { print("ok: \(version) \(sha)") }
default: die("usage: keygen | sign | verify")
}
