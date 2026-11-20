import Foundation
import IOKit.ps

/// The power source, and what Settings ▸ On battery asks of the walls on it (Low Power Mode counts as battery).
struct PowerState: Equatable {
  var onBattery = false
  var lowPower = false
  /// pages draw this many times slower than usual
  var pace = 1.0
  var paused = false

  static func current() -> PowerState {
    var s = PowerState()
    #if TIDEWALL_DEV
    let fake = ProcessInfo.processInfo.environment["TIDEWALL_FAKE_BATTERY"]
    #else
    let fake: String? = nil
    #endif
    if let fake {
      s.onBattery = fake == "1"
    } else {
      let source = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String?
      s.onBattery = source == kIOPSBatteryPowerValue
      s.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    let saving = s.onBattery || s.lowPower
    s.paused = saving && Cfg.battery == 2
    s.pace = saving && Cfg.battery == 1 ? 2 : 1
    return s
  }
}
