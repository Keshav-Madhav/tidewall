using System.Runtime.InteropServices;

namespace Tidewall;

/// A display a wall is drawn on. Real ones come from Windows; --fakescreens N (tests) splits the main display into N
/// side by side, each a display of its own to the walls, so one world across displays can be tried on one screen.
internal sealed record Display(string Name, string Device, Rectangle Bounds, Rectangle WorkingArea, bool Primary)
{
    public static IReadOnlyList<Display> All
    {
        get
        {
            var screens = Screen.AllScreens;
            if (Args.Value("--fakescreens") is not { } v || !int.TryParse(v, out int n) || n < 2)
                return screens.Select(s => new Display(s.DeviceName, s.DeviceName, s.Bounds, s.WorkingArea, s.Primary)).ToList();
            var p = Screen.PrimaryScreen ?? screens[0];
            var list = new List<Display>();
            for (int i = 0; i < n; i++)
            {
                int x0 = p.Bounds.X + p.Bounds.Width * i / n, x1 = p.Bounds.X + p.Bounds.Width * (i + 1) / n;
                var b = Rectangle.FromLTRB(x0, p.Bounds.Y, x1, p.Bounds.Bottom);
                list.Add(new Display($@"\\.\FAKE{i + 1}", p.DeviceName, b, Rectangle.Intersect(b, p.WorkingArea), i == 0));
            }
            return list;
        }
    }
}

/// Displays as people know them (as the Mac names them): the monitor's own name ("DELL U2723QE"), "Built-in Display"
/// for a laptop's panel, with the size, or else the position, added when two share a name. From Windows' display
/// configuration (QueryDisplayConfig), read once per change of displays.
internal static class DisplayNames
{
    static Dictionary<string, string>? cache;
    static string cacheKey = "";

    /// The name for each display, by its device name (\\.\DISPLAY1); none for a display Windows can't name.
    public static string? Of(Display d)
    {
        var real = Screen.AllScreens;
        var key = string.Join("|", real.Select(s => s.DeviceName + s.Bounds));
        if (cache == null || key != cacheKey) { cache = Read(real); cacheKey = key; }
        if (d.Name.StartsWith(@"\\.\FAKE")) return null;                   // (test displays: their numbers)
        return cache.TryGetValue(d.Name, out var n) ? n : null;
    }

    static Dictionary<string, string> Read(Screen[] screens)
    {
        var raw = new Dictionary<string, string>();
        try
        {
            if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out uint np, out uint nm) != 0) return raw;
            var paths = new DISPLAYCONFIG_PATH_INFO[np];
            var modes = new DISPLAYCONFIG_MODE_INFO[nm];
            if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref np, paths, ref nm, modes, IntPtr.Zero) != 0) return raw;
            for (int i = 0; i < np; i++)
            {
                var src = new DISPLAYCONFIG_SOURCE_DEVICE_NAME();
                src.header = new DISPLAYCONFIG_DEVICE_INFO_HEADER { type = 1, size = (uint)Marshal.SizeOf<DISPLAYCONFIG_SOURCE_DEVICE_NAME>(), adapterId = paths[i].sourceInfo.adapterId, id = paths[i].sourceInfo.id };
                if (DisplayConfigGetDeviceInfo(ref src) != 0) continue;
                var tgt = new DISPLAYCONFIG_TARGET_DEVICE_NAME();
                tgt.header = new DISPLAYCONFIG_DEVICE_INFO_HEADER { type = 2, size = (uint)Marshal.SizeOf<DISPLAYCONFIG_TARGET_DEVICE_NAME>(), adapterId = paths[i].targetInfo.adapterId, id = paths[i].targetInfo.id };
                if (DisplayConfigGetDeviceInfo(ref tgt) != 0) continue;
                bool builtIn = tgt.outputTechnology is 0x80000000 or 11 or 13;   // internal, embedded DisplayPort, UDI embedded
                var name = builtIn ? "Built-in Display" : tgt.monitorFriendlyDeviceName?.Trim() ?? "";
                if (name.Length > 0) raw[src.viewGdiDeviceName] = name;
            }
        }
        catch (Exception e) { Log.Write("display names: " + e.Message); }
        // two with the same name: the size, or the order from the left
        var named = new Dictionary<string, string>();
        foreach (var s in screens)
        {
            if (!raw.TryGetValue(s.DeviceName, out var n)) continue;
            var same = screens.Where(o => raw.TryGetValue(o.DeviceName, out var m) && m == n).ToList();
            if (same.Count < 2) { named[s.DeviceName] = n; continue; }
            var sameSize = same.Where(o => o.Bounds.Size == s.Bounds.Size).ToList();
            named[s.DeviceName] = sameSize.Count < 2 ? $"{n} ({s.Bounds.Width}×{s.Bounds.Height})"
                : $"{n} ({sameSize.OrderBy(o => o.Bounds.X).ToList().IndexOf(s) + 1})";
        }
        return named;
    }

    const uint QDC_ONLY_ACTIVE_PATHS = 2;
    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint np, [Out] DISPLAYCONFIG_PATH_INFO[] paths, ref uint nm, [Out] DISPLAYCONFIG_MODE_INFO[] modes, IntPtr topology);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_SOURCE_DEVICE_NAME info);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_TARGET_DEVICE_NAME info);

    [StructLayout(LayoutKind.Sequential)] struct LUID { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] struct DISPLAYCONFIG_PATH_SOURCE_INFO { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }
    [StructLayout(LayoutKind.Sequential)] struct DISPLAYCONFIG_RATIONAL { public uint n, d; }
    [StructLayout(LayoutKind.Sequential)] struct DISPLAYCONFIG_PATH_TARGET_INFO
    {
        public LUID adapterId; public uint id; public uint modeInfoIdx; public uint outputTechnology; public uint rotation; public uint scaling;
        public DISPLAYCONFIG_RATIONAL refreshRate; public uint scanLineOrdering; public int targetAvailable; public uint statusFlags;
    }
    [StructLayout(LayoutKind.Sequential)] struct DISPLAYCONFIG_PATH_INFO { public DISPLAYCONFIG_PATH_SOURCE_INFO sourceInfo; public DISPLAYCONFIG_PATH_TARGET_INFO targetInfo; public uint flags; }
    // (the mode union is 64 bytes after its header: only its size matters here)
    [StructLayout(LayoutKind.Sequential)] struct DISPLAYCONFIG_MODE_INFO { public uint infoType; public uint id; public LUID adapterId; [MarshalAs(UnmanagedType.ByValArray, SizeConst = 48)] public byte[] mode; }
    [StructLayout(LayoutKind.Sequential)] struct DISPLAYCONFIG_DEVICE_INFO_HEADER { public uint type; public uint size; public LUID adapterId; public uint id; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct DISPLAYCONFIG_SOURCE_DEVICE_NAME
    {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string viewGdiDeviceName;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct DISPLAYCONFIG_TARGET_DEVICE_NAME
    {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header; public uint flags; public uint outputTechnology;
        public ushort edidManufactureId; public ushort edidProductCodeId; public uint connectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string monitorFriendlyDeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string monitorDevicePath;
    }
}
