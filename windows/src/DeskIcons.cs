using System.Runtime.InteropServices;

namespace Tidewall;

/// Where the desktop icons are, so each wall keeps them clear (as Finder's icons on the Mac). Asked of the desktop's own
/// shell view (IFolderView, the way Explorer's scripting API reaches it): each item's place and the icon grid's spacing,
/// so its whole box (image and label) and its image, in screen pixels, every 2 s while a wall is showing; neighbours
/// grouped into clusters, so a column of icons is one tall shape rather than twenty specks. No permission is needed.
/// (It used to read Explorer's list view by writing into Explorer's memory: antivirus heuristics take that for code
/// injection, and Windows' stricter sandboxes refuse it outright.)
internal sealed class DeskIcons : IDisposable
{
    public IReadOnlyList<Rectangle> Icons { get; private set; } = [];
    public IReadOnlyList<Rectangle> Images { get; private set; } = [];
    public IReadOnlyList<Rectangle> Clusters { get; private set; } = [];
    public event Action? Changed;

    readonly System.Windows.Forms.Timer timer = new() { Interval = 2000 };
    // (asked on a thread of its own: a call into Explorer waits for Explorer, and a hung Explorer must never hang the
    // walls; the shell's objects live on that thread, and the answers come back to this one)
    readonly System.Collections.Concurrent.BlockingCollection<Action> work = new();
    readonly SynchronizationContext? ui = SynchronizationContext.Current;
    IFolderView? folder;
    bool asking;

    readonly System.Windows.Forms.Timer soon = new() { Interval = 350 };
    IntPtr view;

    /// The mouse let go of a window: if it's the desktop's icon list (a drag ended there), read the icons again shortly
    /// after, as the Mac does, rather than at the next 2-second look.
    public void Released(IntPtr list)
    {
        if (list != view || view == IntPtr.Zero || !timer.Enabled) return;
        soon.Stop(); soon.Start();
    }

    public DeskIcons()
    {
        var shell = new Thread(() => { foreach (var a in work.GetConsumingEnumerable()) a(); }) { IsBackground = true, Name = "desk icons" };
        shell.SetApartmentState(ApartmentState.STA);
        shell.Start();
        soon.Tick += (_, _) => { soon.Stop(); Read(); };
        timer.Tick += (_, _) => Read();
        timer.Start();
        Read();
    }

    /// Paused, locked or away: no need to look.
    public bool Resting { get => !timer.Enabled; set { timer.Enabled = !value; if (!value) Read(); } }

    public void Read()
    {
        if (!Config.DeskIcons) { Set([], []); return; }
        view = ListView();
        if (view == IntPtr.Zero || !Native.IsWindowVisible(view)) { Set([], []); return; }   // icons hidden (View ▸ Show desktop icons off)
        if (asking || ui == null) return;   // (the last look is still waiting on Explorer)
        asking = true;
        var list = view;
        work.Add(() =>
        {
            (List<Rectangle>, List<Rectangle>)? found = null;
            try { found = ItemRects(list); }
            catch (Exception e) { folder = null; Log.Write($"desk icons: {e.Message}"); }   // (Explorer restarted: a new view next time)
            ui.Post(_ => { asking = false; if (found is var (boxes, images)) Set(boxes, images); }, null);
        });
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

    /// Each item's box and image, from the desktop's shell view: its place (the top left of its cell, in the list view's
    /// coordinates), the grid's spacing for the cell, and the icon size for the image (centred at the cell's top).
    (List<Rectangle> boxes, List<Rectangle> images) ItemRects(IntPtr view)
    {
        var boxes = new List<Rectangle>(); var images = new List<Rectangle>();
        folder ??= DesktopFolder();
        if (folder == null) return (boxes, images);
        if (folder.ItemCount(SVGIO_ALLVIEW, out int count) != 0 || count <= 0) return (boxes, images);
        var cell = new Native.POINT();
        if (folder.GetSpacing(ref cell) != 0 || cell.X <= 0 || cell.Y <= 0) return (boxes, images);
        int dpi = Native.DpiOf(view), icon = (int)Math.Round(IconSize() * dpi / 96.0), top = (int)Math.Round(2 * dpi / 96.0);
        for (int i = 0; i < Math.Min(count, 400); i++)
        {
            if (folder.Item(i, out IntPtr pidl) != 0 || pidl == IntPtr.Zero) continue;
            try
            {
                // (an item's place is where its image sits, centred in its cell a little below the cell's top; the label
                // under it takes one or two lines, so the box is the cell's width and most of its height)
                if (folder.GetItemPosition(pidl, out var at) != 0) continue;
                int left = at.X - (cell.X - icon) / 2, y0 = at.Y + top;
                var pts = new[] { new Native.POINT { X = left, Y = y0 }, new Native.POINT { X = left + cell.X, Y = y0 + cell.Y * 4 / 5 }, new Native.POINT { X = at.X, Y = y0 } };
                MapWindowPoints(view, IntPtr.Zero, pts, 3);   // the list view's own coordinates → the screen's
                boxes.Add(Rectangle.FromLTRB(pts[0].X, pts[0].Y, pts[1].X, pts[1].Y));
                images.Add(new Rectangle(pts[2].X, pts[2].Y, icon, icon));
            }
            finally { Marshal.FreeCoTaskMem(pidl); }
        }
        return (boxes, images);
    }

    /// The desktop's shell view: the shell's window list finds the desktop's browser, which hands over its view.
    static IFolderView? DesktopFolder()
    {
        var type = Type.GetTypeFromCLSID(CLSID_ShellWindows);
        if (type == null || Activator.CreateInstance(type) is not IShellWindows windows) return null;
        object loc = CSIDL_DESKTOP; object? root = null;   // (the desktop itself; no root)
        if (windows.FindWindowSW(ref loc, ref root, SWC_DESKTOP, out _, SWFO_NEEDDISPATCH, out object? disp) != 0 || disp is not IServiceProvider sp) return null;
        Guid sid = SID_STopLevelBrowser, iid = typeof(IShellBrowser).GUID;
        if (sp.QueryService(ref sid, ref iid, out object? b) != 0 || b is not IShellBrowser browser) return null;
        if (browser.QueryActiveShellView(out object? v) != 0) return null;
        return v as IFolderView;
    }

    /// The desktop's icon size (View ▸ Small / Medium / Large icons, or Ctrl+scroll), in pixels at 100 %.
    static int IconSize()
    {
        try { return Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\Shell\Bags\1\Desktop", "IconSize", 48) is int n && n >= 16 ? n : 48; }
        catch (Exception) { return 48; }
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
        timer.Dispose(); soon.Dispose();
        work.CompleteAdding();
    }

    const int CSIDL_DESKTOP = 0, SWC_DESKTOP = 8, SWFO_NEEDDISPATCH = 1;
    const uint SVGIO_ALLVIEW = 2;
    static readonly Guid CLSID_ShellWindows = new("9BA05972-F6A8-11CF-A442-00A0C90A8F39");
    static readonly Guid SID_STopLevelBrowser = new("4C96BE40-915C-11CF-99D3-00AA004AE837");

    // the shell's own interfaces, as far as they're used (each in its table's order, every slot before the last one used)
    [ComImport, Guid("85CB6900-4D95-11CF-960C-0080C7F4EE85"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
    interface IShellWindows
    {
        [PreserveSig] int Count(out int count);
        [PreserveSig] int Item(object index, [MarshalAs(UnmanagedType.IDispatch)] out object folder);
        [PreserveSig] int NewEnum([MarshalAs(UnmanagedType.IUnknown)] out object e);
        [PreserveSig] int Register(IntPtr disp, int hwnd, int swClass, out int cookie);
        [PreserveSig] int RegisterPending(int thread, IntPtr loc, IntPtr root, int swClass, out int cookie);
        [PreserveSig] int Revoke(int cookie);
        [PreserveSig] int OnNavigate(int cookie, IntPtr loc);
        [PreserveSig] int OnActivated(int cookie, short active);
        [PreserveSig] int FindWindowSW(ref object loc, ref object? root, int swClass, out int hwnd, int options, [MarshalAs(UnmanagedType.IDispatch)] out object? disp);
    }
    [ComImport, Guid("6D5140C1-7436-11CE-8034-00AA006009FA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IServiceProvider { [PreserveSig] int QueryService(ref Guid service, ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object? obj); }
    [ComImport, Guid("000214E2-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellBrowser
    {
        [PreserveSig] int GetWindow(out IntPtr hwnd);
        [PreserveSig] int ContextSensitiveHelp(int enter);
        [PreserveSig] int InsertMenusSB(IntPtr menu, IntPtr widths);
        [PreserveSig] int SetMenuSB(IntPtr menu, IntPtr ole, IntPtr active);
        [PreserveSig] int RemoveMenusSB(IntPtr menu);
        [PreserveSig] int SetStatusTextSB(IntPtr text);
        [PreserveSig] int EnableModelessSB(int enable);
        [PreserveSig] int TranslateAcceleratorSB(IntPtr msg, ushort id);
        [PreserveSig] int BrowseObject(IntPtr pidl, uint flags);
        [PreserveSig] int GetViewStateStream(uint mode, out IntPtr stream);
        [PreserveSig] int GetControlWindow(uint id, out IntPtr hwnd);
        [PreserveSig] int SendControlMsg(uint id, uint msg, IntPtr w, IntPtr l, out IntPtr ret);
        [PreserveSig] int QueryActiveShellView([MarshalAs(UnmanagedType.IUnknown)] out object? view);
    }
    [ComImport, Guid("CDE725B0-CCC9-4519-917E-325D72FAB4CE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IFolderView
    {
        [PreserveSig] int GetCurrentViewMode(out uint mode);
        [PreserveSig] int SetCurrentViewMode(uint mode);
        [PreserveSig] int GetFolder(ref Guid iid, out IntPtr folder);
        [PreserveSig] int Item(int index, out IntPtr pidl);
        [PreserveSig] int ItemCount(uint flags, out int count);
        [PreserveSig] int Items(uint flags, ref Guid iid, out IntPtr items);
        [PreserveSig] int GetSelectionMarkedItem(out int item);
        [PreserveSig] int GetFocusedItem(out int item);
        [PreserveSig] int GetItemPosition(IntPtr pidl, out Native.POINT at);
        [PreserveSig] int GetSpacing(ref Native.POINT spacing);
    }
    [DllImport("user32.dll")] static extern int MapWindowPoints(IntPtr from, IntPtr to, [In, Out] Native.POINT[] pts, int n);
}
