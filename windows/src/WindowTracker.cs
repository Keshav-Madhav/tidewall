using System.Diagnostics;

namespace Tidewall;

/// Owner: the process ("msedge"), what Tidewall's own rules go by; Name: the app as people know it ("Microsoft Edge"),
/// what the walls show (Gallery's plaques), as the Mac gives them.
internal sealed record TrackedWindow(IntPtr Handle, Rectangle Bounds, string Owner, string Name);

/// Where the windows are. Windows tells us the moment any window moves, shows, hides or changes state (WinEvent hooks,
/// no permission needed); each burst of events is coalesced into one look at the window list on the next turn of the
/// message loop, and a slow timer covers anything the events miss.
internal sealed class WindowTracker : IDisposable
{
    public event Action<IReadOnlyList<TrackedWindow>, bool>? Changed;

    readonly Control loop;
    readonly List<IntPtr> hooks = [];
    readonly Native.WinEventProc onEvent;   // (held: the hooks call it from native code)
    readonly System.Windows.Forms.Timer slow = new() { Interval = 500 };
    readonly HashSet<IntPtr> ignore = [];
    readonly Dictionary<uint, string> owners = [];
    readonly Dictionary<IntPtr, string> classes = [];   // a window's class never changes: asked once
    readonly Stopwatch sinceLook = Stopwatch.StartNew();
    readonly System.Windows.Forms.Timer trailing = new() { Interval = 8 };
    readonly int me = Environment.ProcessId;
    IReadOnlyList<TrackedWindow> last = [];
    bool pending, moving;

    public IReadOnlyList<TrackedWindow> Windows => last;
    public bool Live => moving || (Native.GetAsyncKeyState(Native.VK_LBUTTON) & 0x8000) != 0;

    /// Windows of this process that count as windows (test windows, the Settings window).
    public HashSet<IntPtr> OwnWindows { get; } = [];

    public WindowTracker(Control loop)
    {
        this.loop = loop;
        onEvent = OnEvent;
        Hook(Native.EVENT_SYSTEM_FOREGROUND, Native.EVENT_SYSTEM_FOREGROUND);
        Hook(Native.EVENT_SYSTEM_MOVESIZESTART, Native.EVENT_SYSTEM_MOVESIZEEND);
        Hook(Native.EVENT_SYSTEM_MINIMIZESTART, Native.EVENT_SYSTEM_MINIMIZEEND);
        Hook(Native.EVENT_OBJECT_DESTROY, Native.EVENT_OBJECT_HIDE);
        Hook(Native.EVENT_OBJECT_LOCATIONCHANGE, Native.EVENT_OBJECT_LOCATIONCHANGE);
        Hook(Native.EVENT_OBJECT_CLOAKED, Native.EVENT_OBJECT_UNCLOAKED);
        Hook(EVENT_SYSTEM_CAPTURESTART, EVENT_SYSTEM_CAPTUREEND);           // (only on clicks: cheap)
        slow.Tick += (_, _) => Look();
        slow.Start();
        trailing.Tick += (_, _) => { trailing.Stop(); pending = false; Look(); };
    }

    /// The fastest a look is worth while a window moves: one per frame of the fastest display (a gaming mouse reports
    /// up to 1000 times a second; the pages can't draw faster than the screen).
    public int MinLookMs { get; set; } = 8;

    /// Every wall resting (paused, locked, nobody at the PC): no safety-net looks; the events still come.
    public bool Resting
    {
        get => !slow.Enabled;
        set { if (value == !slow.Enabled) return; slow.Enabled = !value; if (!value) Look(); }
    }

    const uint EVENT_SYSTEM_CAPTURESTART = 0x8, EVENT_SYSTEM_CAPTUREEND = 0x9;
    /// A window the mouse had captured was let go (a drag ended in it: on the desktop, an icon moved).
    public event Action<IntPtr>? Released;

    void Hook(uint min, uint max) =>
        hooks.Add(Native.SetWinEventHook(min, max, IntPtr.Zero, onEvent, 0, 0, Native.WINEVENT_OUTOFCONTEXT));

    void OnEvent(IntPtr hook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
    {
        if (evt == Native.EVENT_SYSTEM_MOVESIZESTART) moving = true;
        else if (evt == Native.EVENT_SYSTEM_MOVESIZEEND) moving = false;
        // the mouse let go of a window it held (the end of a drag): the desktop's icon list among them, after an icon's moved
        if (evt == EVENT_SYSTEM_CAPTUREEND) { if (hwnd != IntPtr.Zero) Released?.Invoke(hwnd); return; }
        if (evt == EVENT_SYSTEM_CAPTURESTART) return;
        else if (idObject != Native.OBJID_WINDOW || hwnd == IntPtr.Zero) return;
        if (evt == Native.EVENT_OBJECT_DESTROY) classes.Remove(hwnd);
        // a child window (a browser's page, a video, an Office pane) moving can't move a top-level window
        else if ((evt == Native.EVENT_OBJECT_LOCATIONCHANGE || evt == Native.EVENT_OBJECT_SHOW) && Native.GetAncestor(hwnd, Native.GA_ROOT) != hwnd) return;
        if (pending) return;
        pending = true;
        var wait = MinLookMs - (int)sinceLook.ElapsedMilliseconds;
        if (wait > 1) { trailing.Interval = wait; trailing.Start(); }
        else loop.BeginInvoke(() => { pending = false; Look(); });
    }

    public void Look()
    {
        sinceLook.Restart();
        var now = Read();
        bool live = Live;
        if (now.SequenceEqual(last) && !(liveBefore && !live)) { liveBefore = live; return; }
        last = now;
        liveBefore = live;
        Changed?.Invoke(now, live);
    }
    bool liveBefore;

    public void Ignore(IntPtr handle) => ignore.Add(handle);

    /// The windows on the desktop now, front to back.
    List<TrackedWindow> Read()
    {
        var list = new List<TrackedWindow>();
        Native.EnumWindows((h, _) =>
        {
            if (Counts(h, out var bounds)) list.Add(new TrackedWindow(h, bounds, Owner(h), AppName(h)));
            return true;
        }, IntPtr.Zero);
        return list;
    }

    bool Counts(IntPtr h, out Rectangle bounds)
    {
        bounds = Rectangle.Empty;
        // the cheap checks first: the DWM ones (cloaked, the frame) only for windows that could count
        if (ignore.Contains(h) || !Native.IsWindowVisible(h) || Native.IsIconic(h)) return false;
        Native.GetWindowThreadProcessId(h, out uint pid);
        if (pid == me && !OwnWindows.Contains(h)) return false;
        if ((Native.ExStyle(h) & Native.WS_EX_TOOLWINDOW) != 0) return false;
        if (!classes.TryGetValue(h, out var cls)) classes[h] = cls = Native.ClassName(h);
        if (cls is "Progman" or "WorkerW" or "Shell_TrayWnd" or "Shell_SecondaryTrayWnd" or "NotifyIconOverflowWindow"
            or "Windows.UI.Core.CoreWindow" or "XamlExplorerHostIslandWindow" or "TopLevelWindowForOverflowXamlIsland") return false;
        if (Native.GetWindowTextLength(h) == 0 && cls != "ApplicationFrameWindow") return false;   // untitled helpers and overlays
        // Explorer's own windows are folder windows (CabinetWClass); the rest of it is the shell's furniture (taskbar
        // thumbnails, the minimise animation, flyouts), as the Dock is on a Mac
        if (cls != "CabinetWClass" && Owner(h) == "explorer") return false;
        if (Native.IsCloaked(h)) return false;
        bounds = Native.VisibleBounds(h);
        return bounds.Width >= 40 && bounds.Height >= 40;
    }

    string Owner(IntPtr h)
    {
        Native.GetWindowThreadProcessId(h, out uint pid);
        if (owners.TryGetValue(pid, out var name)) return name;
        try { name = Process.GetProcessById((int)pid).ProcessName; } catch (ArgumentException) { name = ""; }
        owners[pid] = name;
        return name;
    }

    readonly Dictionary<uint, string> names = [];

    string AppName(IntPtr h)
    {
        // Store apps (Settings, Calculator, Photos) all run in one frame host: the window's own title is the app's name
        if (classes.TryGetValue(h, out var cls) && cls == "ApplicationFrameWindow") return Native.Title(h) is { Length: > 0 } t ? t : Owner(h);
        Native.GetWindowThreadProcessId(h, out uint pid);
        if (names.TryGetValue(pid, out var name)) return name;
        name = Owner(h);
        try
        {
            if (Native.ImagePath(pid) is { } path)
            {
                var info = FileVersionInfo.GetVersionInfo(path);
                var described = (info.FileDescription ?? "").Trim();
                if (described.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) described = described[..^4];   // ("Notepad.exe": some describe themselves by their file)
                if (described.Length is > 0 and < 40) name = described;
                else if ((info.ProductName ?? "").Trim() is { Length: > 0 and < 40 } product) name = product;
            }
        }
        catch (Exception) { }                                              // (a process that went, a file we may not read)
        if (names.Count > 500) names.Clear();
        return names[pid] = name;
    }

    public void Dispose()
    {
        slow.Dispose();
        trailing.Dispose();
        foreach (var h in hooks) Native.UnhookWinEvent(h);
    }
}
