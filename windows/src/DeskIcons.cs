using System.Runtime.InteropServices;

namespace Tidewall;

/// Where the desktop icons are, so each wall keeps them clear (as Finder's icons on the Mac). Read from the desktop's
/// icon list (a list view inside Explorer's desktop window): each item's whole box (image and label) and its image,
/// in screen pixels, every 2 s while a wall is showing; neighbours grouped into clusters, so a column of icons is one
/// tall shape rather than twenty specks. No permission is needed for any of it.
internal sealed class DeskIcons : IDisposable
{
    public IReadOnlyList<Rectangle> Icons { get; private set; } = [];
    public IReadOnlyList<Rectangle> Images { get; private set; } = [];
    public IReadOnlyList<Rectangle> Clusters { get; private set; } = [];
    public event Action? Changed;

    readonly System.Windows.Forms.Timer timer = new() { Interval = 2000 };
    IntPtr process;
    uint processId;

    public DeskIcons()
    {
        timer.Tick += (_, _) => Read();
        timer.Start();
        Read();
    }

    /// Paused, locked or away: no need to look.
    public bool Resting { get => !timer.Enabled; set { timer.Enabled = !value; if (!value) Read(); } }

    public void Read()
    {
        if (!Config.DeskIcons) { Set([], []); return; }
        var view = ListView();
        if (view == IntPtr.Zero || !Native.IsWindowVisible(view)) { Set([], []); return; }   // icons hidden (View ▸ Show desktop icons off)
        try
        {
            var (boxes, images) = ItemRects(view);
            Set(boxes, images);
        }
        catch (Exception e) { Log.Write($"desk icons: {e.Message}"); }
    }

    /// The desktop's icon list: in the window that holds the desktop's shell view (Progman, or a WorkerW before 24H2).
    static IntPtr ListView()
    {
        IntPtr defView = Native.FindWindowEx(Native.FindWindow("Progman", null), IntPtr.Zero, "SHELLDLL_DefView", null);
        if (defView == IntPtr.Zero)
            Native.EnumWindows((h, _) =>
            {
                if (Native.ClassName(h) != "WorkerW") return true;
                defView = Native.FindWindowEx(h, IntPtr.Zero, "SHELLDLL_DefView", null);
                return defView == IntPtr.Zero;
            }, IntPtr.Zero);
        return defView == IntPtr.Zero ? IntPtr.Zero : Native.FindWindowEx(defView, IntPtr.Zero, "SysListView32", null);
    }

    const uint LVM_GETITEMCOUNT = 0x1004, LVM_GETITEMRECT = 0x100E;
    const int LVIR_BOUNDS = 0, LVIR_ICON = 1;

    /// Each item's rectangle, asked of the list view in Explorer's own memory (a list view only writes into its process).
    (List<Rectangle> boxes, List<Rectangle> images) ItemRects(IntPtr view)
    {
        var boxes = new List<Rectangle>(); var images = new List<Rectangle>();
        Native.SendMessageTimeout(view, LVM_GETITEMCOUNT, IntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG, 300, out var n);
        int count = (int)n;
        if (count <= 0) return (boxes, images);
        Native.GetWindowThreadProcessId(view, out uint pid);
        if (pid != processId || process == IntPtr.Zero)
        {
            if (process != IntPtr.Zero) CloseHandle(process);
            process = OpenProcess(PROCESS_VM_OPERATION | PROCESS_VM_READ | PROCESS_VM_WRITE, false, pid);
            processId = pid;
            if (process == IntPtr.Zero) throw new InvalidOperationException($"can't reach Explorer ({Marshal.GetLastWin32Error()})");
        }
        IntPtr remote = VirtualAllocEx(process, IntPtr.Zero, 16, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        if (remote == IntPtr.Zero) throw new InvalidOperationException("no room in Explorer for a rectangle");
        try
        {
            Rectangle Ask(int i, int part)
            {
                var r = new Native.RECT { Left = part };
                WriteProcessMemory(process, remote, ref r, 16, out _);
                if (Native.SendMessageTimeout(view, LVM_GETITEMRECT, (IntPtr)i, remote, SMTO_ABORTIFHUNG, 300, out var ok) == IntPtr.Zero || ok == IntPtr.Zero) return Rectangle.Empty;
                ReadProcessMemory(process, remote, out r, 16, out _);
                var pts = new[] { new Native.POINT { X = r.Left, Y = r.Top }, new Native.POINT { X = r.Right, Y = r.Bottom } };
                MapWindowPoints(view, IntPtr.Zero, pts, 2);   // the list view's own coordinates → the screen's
                return Rectangle.FromLTRB(pts[0].X, pts[0].Y, pts[1].X, pts[1].Y);
            }
            for (int i = 0; i < Math.Min(count, 400); i++)
            {
                var box = Ask(i, LVIR_BOUNDS);
                if (box.IsEmpty) continue;
                boxes.Add(box);
                images.Add(Ask(i, LVIR_ICON) is { IsEmpty: false } im ? im : box);
            }
        }
        finally { VirtualFreeEx(process, remote, 0, MEM_RELEASE); }
        return (boxes, images);
    }

    void Set(List<Rectangle> boxes, List<Rectangle> images)
    {
        if (boxes.SequenceEqual(Icons) && images.SequenceEqual(Images)) return;   // checked before clustering: that's the costly part
        float dpi; using (var g = Graphics.FromHwnd(IntPtr.Zero)) dpi = g.DpiX;
        Config.IconsPresent = boxes.Count > 0;
        Icons = boxes; Images = images; Clusters = Cluster(boxes, (int)Math.Round(26 * dpi / 96));   // (26 pt, as on the Mac)
        Changed?.Invoke();
    }

    /// Neighbouring icons (within a gap of each other) as one shape.
    static List<Rectangle> Cluster(IReadOnlyList<Rectangle> rs, int gap)
    {
        Rectangle Halo(Rectangle r) => Rectangle.Inflate(r, gap / 2, gap / 2);
        var outs = rs.ToList();
        for (bool merged = true; merged;)
        {
            merged = false;
            for (int i = 0; i < outs.Count && !merged; i++)
                for (int j = i + 1; j < outs.Count; j++)
                    if (Halo(outs[i]).IntersectsWith(Halo(outs[j]))) { outs[i] = Rectangle.Union(outs[i], outs[j]); outs.RemoveAt(j); merged = true; break; }
        }
        return outs;
    }

    public void Dispose()
    {
        timer.Dispose();
        if (process != IntPtr.Zero) CloseHandle(process);
    }

    const uint SMTO_ABORTIFHUNG = 0x2;
    const uint PROCESS_VM_OPERATION = 0x8, PROCESS_VM_READ = 0x10, PROCESS_VM_WRITE = 0x20;
    const uint MEM_COMMIT = 0x1000, MEM_RESERVE = 0x2000, MEM_RELEASE = 0x8000, PAGE_READWRITE = 0x04;
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr VirtualAllocEx(IntPtr p, IntPtr at, int size, uint type, uint protect);
    [DllImport("kernel32.dll")] static extern bool VirtualFreeEx(IntPtr p, IntPtr at, int size, uint type);
    [DllImport("kernel32.dll")] static extern bool WriteProcessMemory(IntPtr p, IntPtr at, ref Native.RECT r, int size, out IntPtr written);
    [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr p, IntPtr at, out Native.RECT r, int size, out IntPtr read);
    [DllImport("user32.dll")] static extern int MapWindowPoints(IntPtr from, IntPtr to, [In, Out] Native.POINT[] pts, int n);
}
