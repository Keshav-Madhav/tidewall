import Cocoa
import CoreLocation

/// Where you are, from Location Services, so the walls that draw the real sky (Courtyard's sun and shadows, Celestial
/// Atlas's stars) draw it over you. A time zone alone put all of India at Kolkata and all of China at Shanghai: an
/// hour or more off at sunset. macOS asks once, at the first launch; until it's answered (or if you say no) the city
/// of your time zone stands in.
///
/// Kept rounded to a tenth of a degree (about 10 km) in Tidewall's own settings and used only on this Mac; the town's
/// name comes from Apple's own lookup (the one Location Services already uses). Looked again every six hours and when
/// your time zone changes; the walls are redrawn only when you've moved more than about 25 km.
final class Locator: NSObject, CLLocationManagerDelegate {
  static let shared = Locator()
  /// You moved (or the first fix came): the sky's pages need drawing again.
  var onMove: () -> Void = {}
  private let manager = CLLocationManager()
  private var timer: Timer?

  struct Here { let lat: Double, lon: Double, name: String?, at: Date }
  static var here: Here? {
    guard let d = Cfg.d.dictionary(forKey: "here"), let lat = d["lat"] as? Double, let lon = d["lon"] as? Double else { return nil }
    return Here(lat: lat, lon: lon, name: d["name"] as? String, at: d["at"] as? Date ?? .distantPast)
  }

  func start() {
    // (test copies, benches and a bare binary never ask: only the real app does)
    guard !TestIsolation.on, !benchMode, Bundle.main.bundleIdentifier != nil else { return }
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() } else { look() }
    timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.look(force: true) }
    NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in self?.look(force: true) }
  }

  /// One fix, if we may and the last is old (or we're told to).
  private func look(force: Bool = false) {
    guard manager.authorizationStatus == .authorizedAlways else { return }
    if !force, let h = Self.here, Date().timeIntervalSince(h.at) < 6 * 3600 { return }
    manager.requestLocation()
  }

  /// What the Settings window and a problem report say about it.
  var status: String {
    switch manager.authorizationStatus {
    case .authorizedAlways: return Self.here == nil ? "allowed, no fix yet" : "on"
    case .denied: return "turned off for Tidewall"
    case .restricted: return "restricted"
    case .notDetermined: return "not asked yet"
    @unknown default: return "?"
    }
  }

  func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
    log("location: \(status)")
    look()
  }

  func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let c = locations.last?.coordinate, CLLocationCoordinate2DIsValid(c) else { return }
    let lat = (c.latitude * 10).rounded() / 10, lon = (c.longitude * 10).rounded() / 10
    let was = Self.here
    let moved = was.map { abs($0.lat - lat) > 0.25 || abs($0.lon - lon) > 0.25 } ?? true
    store(lat, lon, name: moved ? nil : was?.name)
    guard moved else { return }
    log("location: moved (the sky is redrawn)")
    onMove()
    // the town's name, for the walls that print it (Celestial's cartouche)
    CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon)) { [weak self] marks, _ in
      guard let name = marks?.first.flatMap({ $0.locality ?? $0.subAdministrativeArea ?? $0.administrativeArea }) else { return }
      DispatchQueue.main.async {
        guard let h = Self.here, h.lat == lat, h.lon == lon, h.name != name else { return }
        self?.store(lat, lon, name: name)
        self?.onMove()
      }
    }
  }

  func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
    log("location: no fix (\((error as NSError).code))")
  }

  private func store(_ lat: Double, _ lon: Double, name: String?) {
    var d: [String: Any] = ["lat": lat, "lon": lon, "at": Date()]
    if let name { d["name"] = name }
    Cfg.d.set(d, forKey: "here")
  }
}
