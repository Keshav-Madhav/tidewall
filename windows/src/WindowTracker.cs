using System.Diagnostics;

namespace Tidewall;

internal sealed record TrackedWindow(IntPtr Handle, Rectangle Bounds, string Owner);

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
        slow.Tick += (_, _) => Look();
        slow.Start();
    }

    void Hook(uint min, uint max) =>
        hooks.Add(Native.SetWinEventHook(min, max, IntPtr.Zero, onEvent, 0, 0, Native.WINEVENT_OUTOFCONTEXT));

    void OnEvent(IntPtr hook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
    {
        if (evt == Native.EVENT_SYSTEM_MOVESIZESTART) moving = true;
        else if (evt == Native.EVENT_SYSTEM_MOVESIZEEND) moving = false;
        else if (idObject != Native.OBJID_WINDOW || hwnd == IntPtr.Zero) return;
        if (pending) return;
        pending = true;
        loop.BeginInvoke(() => { pending = false; Look(); });
    }

    public void Look()
    {
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
            if (Counts(h, out var bounds)) list.Add(new TrackedWindow(h, bounds, Owner(h)));
            return true;
        }, IntPtr.Zero);
        return list;
    }

    bool Counts(IntPtr h, out Rectangle bounds)
    {
        bounds = Rectangle.Empty;
        if (ignore.Contains(h) || !Native.IsWindowVisible(h) || Native.IsIconic(h) || Native.IsCloaked(h)) return false;
        Native.GetWindowThreadProcessId(h, out uint pid);
        if (pid == me && !OwnWindows.Contains(h)) return false;
        if ((Native.ExStyle(h) & Native.WS_EX_TOOLWINDOW) != 0) return false;
        var cls = Native.ClassName(h);
        if (cls is "Progman" or "WorkerW" or "Shell_TrayWnd" or "Shell_SecondaryTrayWnd" or "NotifyIconOverflowWindow"
            or "Windows.UI.Core.CoreWindow" or "XamlExplorerHostIslandWindow" or "TopLevelWindowForOverflowXamlIsland") return false;
        if (Native.GetWindowTextLength(h) == 0 && cls != "ApplicationFrameWindow") return false;   // untitled helpers and overlays
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

    public void Dispose()
    {
        slow.Dispose();
        foreach (var h in hooks) Native.UnhookWinEvent(h);
    }
}
