using System.Runtime.InteropServices;

namespace Tidewall;

/// The power source, and what Settings ▸ On battery asks of the walls on it (Battery saver counts as battery, as Low
/// Power Mode does on a Mac): Calmer draws at half the rate, Pause rests them.
internal readonly record struct PowerState(bool OnBattery, bool Saver, double Pace, bool Paused)
{
    public static PowerState Current()
    {
        bool battery = false, saver = false;
        if (Environment.GetEnvironmentVariable("TIDEWALL_FAKE_BATTERY") is { Length: > 0 } fake) battery = fake == "1";   // (tests)
        else if (GetSystemPowerStatus(out var s)) { battery = s.ACLineStatus == 0; saver = s.SystemStatusFlag == 1; }
        bool saving = battery || saver;
        return new PowerState(battery, saver, saving && Config.Battery == 1 ? 2 : 1, saving && Config.Battery == 2);
    }

    [StructLayout(LayoutKind.Sequential)]
    struct SYSTEM_POWER_STATUS { public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag; public int BatteryLifeTime, BatteryFullLifeTime; }
    [DllImport("kernel32.dll")] static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS s);
}
