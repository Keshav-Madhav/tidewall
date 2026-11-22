namespace Tidewall;

/// The layer Windows draws the desktop picture in, behind the icons. Asking Progman (the desktop) for 0x052C makes it
/// split off a WorkerW window for it; a window put there shows as the wallpaper, under the icons.
///
/// Before Windows 11 24H2 that WorkerW is a top-level window just behind the one holding the icons (SHELLDLL_DefView).
/// From 24H2 it's a child of Progman, beside the icons: a wallpaper then goes into Progman itself, just below the icons.
internal static class DesktopLayer
{
    const uint SpawnWorker = 0x052C;

    public sealed record Host(IntPtr Parent, IntPtr Icons, bool InsideProgman);

    public static Host Find()
    {
        var progman = Native.FindWindow("Progman", null);
        Native.SendMessageTimeout(progman, SpawnWorker, new IntPtr(0xD), new IntPtr(0x1), Native.SMTO_NORMAL, 1000, out _);
        Native.SendMessageTimeout(progman, SpawnWorker, IntPtr.Zero, IntPtr.Zero, Native.SMTO_NORMAL, 1000, out _);

        var icons = Native.FindWindowEx(progman, IntPtr.Zero, "SHELLDLL_DefView", null);
        if (icons != IntPtr.Zero && Native.FindWindowEx(progman, IntPtr.Zero, "WorkerW", null) != IntPtr.Zero)
            return new Host(progman, icons, InsideProgman: true);

        IntPtr worker = IntPtr.Zero, iconsTop = IntPtr.Zero;
        Native.EnumWindows((top, _) =>
        {
            var view = Native.FindWindowEx(top, IntPtr.Zero, "SHELLDLL_DefView", null);
            if (view == IntPtr.Zero) return true;
            iconsTop = view;
            worker = Native.FindWindowEx(IntPtr.Zero, top, "WorkerW", null);
            return false;
        }, IntPtr.Zero);
        return new Host(worker != IntPtr.Zero ? worker : progman, iconsTop, InsideProgman: false);
    }

    /// Puts a window into the desktop layer at a screen rectangle (physical pixels).
    /// `below`: a wall this one replaces, which stays on top (its picture showing) until this one is ready.
    public static void Attach(IntPtr window, Host host, Rectangle screen, IntPtr below = default)
    {
        var style = Native.GetWindowLongPtr(window, Native.GWL_STYLE).ToInt64();
        Native.SetWindowLongPtr(window, Native.GWL_STYLE, new IntPtr((style & ~Native.WS_POPUP) | Native.WS_CHILD));
        Native.SetParent(window, host.Parent);
        if (host.InsideProgman)
        {
            // 24H2: a child of Progman must be layered to be composed, and sit just below the icons
            Native.SetWindowLongPtr(window, Native.GWL_EXSTYLE, new IntPtr(Native.ExStyle(window) | Native.WS_EX_LAYERED));
            Native.SetLayeredWindowAttributes(window, 0, 255, Native.LWA_ALPHA);
        }
        var origin = SystemInformation.VirtualScreen.Location;
        bool under = below != IntPtr.Zero && Native.IsWindow(below);
        Native.SetWindowPos(window, under ? below : host.InsideProgman ? host.Icons : IntPtr.Zero,
            screen.X - origin.X, screen.Y - origin.Y, screen.Width, screen.Height,
            Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW | (under || host.InsideProgman ? 0 : Native.SWP_NOZORDER));
    }
}
