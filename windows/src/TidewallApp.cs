using Microsoft.Win32;

namespace Tidewall;

/// Owns the walls (one per display), the window tracker that feeds them, the tray menu, and everything that decides
/// whether they draw: a full-screen app over a display, the screen locked, nobody at the PC, the user's pause.
internal sealed class TidewallApp : ApplicationContext
{
    readonly Control loop = new();
    readonly WindowTracker tracker;
    readonly DeskIcons deskIcons;
    readonly NotifyIcon tray;
    readonly System.Windows.Forms.Timer clock = new() { Interval = 1000 };
    readonly System.Windows.Forms.Timer pointer = new() { Interval = 16 };
    readonly List<Wallpaper> walls = [];
    DesktopLayer.Host? layer;
    bool locked, idle;
    Point lastPointer = new(-1, -1);
    Wallpaper? pointerWall;

    public IReadOnlyList<Wallpaper> Walls => walls;
    public WindowTracker Tracker => tracker;
    public DeskIcons DeskIcons => deskIcons;
    public Updater Updates { get; }
    public Control Loop => loop;

    public TidewallApp()
    {
        loop.CreateControl();
        _ = loop.Handle;
        tracker = new WindowTracker(loop);
        tracker.Changed += (_, live) => Dispatch(live);
        deskIcons = new DeskIcons();
        Updates = new Updater();
        Updates.Changed += () => settings?.PushState();
        deskIcons.Changed += () => { foreach (var w in walls) if (w.Ready) w.SendDeskIcons(deskIcons, WorldFor(w)); };
        tray = new NotifyIcon { Icon = AppIcon(), Text = "Tidewall", Visible = !Args.Has("--test") };
        tray.DoubleClick += (_, _) => ShowSettings();
        RebuildMenu();
        BuildWalls();
        if (Args.Has("--settings")) loop.BeginInvoke(() => ShowSettings(Args.Value("--settings")));

        rebuildSoon.Tick += (_, _) => { rebuildSoon.Stop(); BuildWalls(); };
        SystemEvents.DisplaySettingsChanged += (_, _) => loop.BeginInvoke(() => RebuildSoon("displays changed"));
        // Explorer restarted (it crashed, or someone restarted it): the desktop window the walls lived in went with it.
        // It says so to every top-level window ("TaskbarCreated"); the walls are made again in the new one.
        explorerWatch = new ExplorerWatch(() => loop.BeginInvoke(() => RebuildSoon("Explorer restarted")), () => loop.BeginInvoke(() => ShowSettings()),
            () => loop.BeginInvoke(() => { Log.Write("asked to quit (being uninstalled)"); ExitThread(); }));
        SystemEvents.SessionSwitch += (_, e) =>
        {
            if (e.Reason is SessionSwitchReason.SessionLock or SessionSwitchReason.ConsoleDisconnect) { locked = true; Updates.Locked(); }
            if (e.Reason is SessionSwitchReason.SessionUnlock or SessionSwitchReason.ConsoleConnect) locked = false;
            loop.BeginInvoke(() => Dispatch(false));
        };
        clock.Tick += (_, _) => CheckIdle();
        clock.Start();
        pointer.Tick += (_, _) => FollowPointer();
        Log.Write($"Tidewall {Config.Version} on Windows {Environment.OSVersion.Version}; themes {Config.ThemesRoot}");
    }

    /// A wall whose desktop window has gone (Explorer restarted) can't be closed cleanly: WebView2 throws, and it's let go.
    static void CloseWall(Wallpaper w)
    {
        try { w.Close(); } catch (Exception e) { Log.Write($"a wall closed uncleanly ({e.GetType().Name}): its desktop had gone"); }
    }

    /// From the uninstaller: the running copy quits (it's being removed); if it hasn't within 5 s, it's stopped.
    public static void AskRunningToQuit()
    {
        var h = Native.FindWindow(null, ExplorerWatch.Caption);
        if (h == IntPtr.Zero) return;
        Native.GetWindowThreadProcessId(h, out uint pid);
        Native.SendMessageTimeout(h, ExplorerWatch.Quit, IntPtr.Zero, IntPtr.Zero, 0x2, 2000, out _);
        try
        {
            using var p = System.Diagnostics.Process.GetProcessById((int)pid);
            if (!p.WaitForExit(5000)) p.Kill();
        }
        catch (ArgumentException) { }                                     // (already gone)
    }

    /// From a second copy: the running one shows its window (and may bring it to the front: this process just started).
    public static void AskRunningToShowSettings()
    {
        var h = Native.FindWindow(null, ExplorerWatch.Caption);
        if (h == IntPtr.Zero) return;
        Native.GetWindowThreadProcessId(h, out uint pid);
        AllowSetForegroundWindow(pid);
        Native.SendMessageTimeout(h, ExplorerWatch.ShowSettings, IntPtr.Zero, IntPtr.Zero, 0x2, 2000, out _);
    }
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool AllowSetForegroundWindow(uint pid);

    public static Icon AppIcon()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Tidewall.ico");
        return File.Exists(path) ? new Icon(path) : SystemIcons.Application;
    }

    // MARK: walls

    void BuildWalls()
    {
        foreach (var w in walls) CloseWall(w);
        walls.Clear();
        pointerWall = null;                                               // (it was one of those)
        layer = DesktopLayer.Find();
        Log.Write($"desktop layer: {(layer.InsideProgman ? "inside Progman (24H2)" : "WorkerW")} {layer.Parent}");
        foreach (var screen in Display.All)
        {
            var wall = new Wallpaper(screen, Config.ThemeFor(screen));
            wall.BecameReady += _ => Dispatch(false);
            walls.Add(wall);
            _ = StartWall(wall);
        }
        tracker.MinLookMs = Math.Max(4, 1000 / Math.Max(1, walls.Max(w => w.RefreshRate())));
    }

    async Task StartWall(Wallpaper wall)
    {
        try { await wall.StartAsync(layer!); }
        catch (Exception e) when (wall.IsDisposed) { Log.Write($"a {wall.Theme} wall closed while it started ({e.GetType().Name})"); }   // (replaced by a newer one)
        catch (Exception e) { Log.Write($"JSERR could not start the {wall.Theme} wall: {e.Message}"); }
    }

    /// One world across the displays that show a spanning wall with the same scale (mixed scales: each its own).
    IReadOnlyList<Display>? WorldFor(Wallpaper w)
    {
        if (!Config.SpanWorlds || !Config.SpanThemes.Contains(w.Theme)) return null;
        var same = walls.Where(o => o.Theme == w.Theme && o.DeviceDpi == w.DeviceDpi).Select(o => o.Screen).ToList();
        return same.Count > 1 ? same : null;
    }

    public void Dispatch(bool live)
    {
        var windows = tracker.Windows;
        foreach (var w in walls)
        {
            if (!w.Ready) continue;
            w.SendDesk(WorldFor(w));
            w.SendDeskIcons(deskIcons, WorldFor(w));
            // nothing of the wall shows but behind the taskbar (a maximised window, a full-screen app): it rests, as on a Mac
            bool covered = !live && Covered.IsCovered(w.Screen.WorkingArea, windows.Select(t => t.Bounds));
            w.SetPaused(Config.Paused || locked || idle || covered);
            if (!w.Paused || live) w.SendWindows(Config.ReactWindows ? windows : Array.Empty<TrackedWindow>(), live);   // windows off: it carries on as if they weren't there
        }
        // nothing to follow the pointer for: no ticks at all (it ran 60 times a second all day, paused or not)
        pointer.Enabled = walls.Any(w => w.Ready && !w.Paused && w.WantsCursor) && !locked && !idle;
        tracker.Resting = deskIcons.Resting = Config.Paused || locked || idle;
    }

    readonly ExplorerWatch explorerWatch;
    readonly System.Windows.Forms.Timer rebuildSoon = new() { Interval = 800 };

    /// Every wall again, a moment from now: the reasons come in bursts (Explorer's broadcast and the desktop window
    /// going; a display change in several steps), and one rebuild serves them all.
    void RebuildSoon(string why)
    {
        Log.Write($"{why}: the walls again");
        rebuildSoon.Stop(); rebuildSoon.Start();
    }

    void CheckIdle()
    {
        if (layer != null && !Native.IsWindow(layer.Parent) && !rebuildSoon.Enabled) RebuildSoon("the desktop window is gone");   // (in case the broadcast was missed)
        bool now = Config.IdleMinutes > 0 && Native.IdleSeconds() > Config.IdleMinutes * 60;
        if (now == idle) return;
        idle = now;
        Log.Write(idle ? "idle: resting" : "input: awake");
        Dispatch(false);
    }

    void FollowPointer()
    {
        if (!Config.ReactCursor || !Native.GetCursorPos(out var p)) return;
        var pt = new Point(p.X, p.Y);
        if (pt == lastPointer) return;
        lastPointer = pt;
        var wall = walls.FirstOrDefault(w => w.Frame.Contains(pt));
        if (pointerWall != null && pointerWall != wall) pointerWall.CursorOff();
        pointerWall = wall;
        wall?.SendCursor(pt, tracker.Windows.Any(t => t.Bounds.Contains(pt)));
    }

    // MARK: the Settings window

    SettingsWindow? settings;

    public void ShowSettings(string? page = null)
    {
        if (settings == null || settings.IsDisposed)
        {
            settings = new SettingsWindow(this, page);
            settings.FormClosed += (_, _) => settings = null;   // closed: it and its preview let go of everything
            settings.Show();
        }
        else
        {
            if (page != null) settings.ShowPage(page);
            if (settings.WindowState == FormWindowState.Minimized) settings.WindowState = FormWindowState.Normal;
            settings.Activate();
        }
    }

    public SettingsWindow? Settings => settings;

    /// After a change of walls, displays or frame rate: every wall again, and the menu and window told.
    public void RebuildWalls() { BuildWalls(); RefreshMenu(); }

    public void RefreshMenu() { RebuildMenu(); settings?.PushState(); }

    // MARK: tray menu

    void RebuildMenu()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("Settings…", null, (_, _) => ShowSettings());
        menu.Items.Add(new ToolStripSeparator());
        var themes = new ToolStripMenuItem("Wall");
        foreach (var (id, label) in Config.Themes)
        {
            var item = new ToolStripMenuItem(label) { Checked = Config.Theme == id };
            item.Click += (_, _) => { Config.ClearDisplayThemes(); Config.Theme = id; RebuildWalls(); };
            themes.DropDownItems.Add(item);
        }
        menu.Items.Add(themes);
        menu.Items.Add(new ToolStripSeparator());
        var pause = new ToolStripMenuItem("Pause") { Checked = Config.Paused };
        pause.Click += (_, _) => { Config.Paused = !Config.Paused; Dispatch(false); RefreshMenu(); };
        menu.Items.Add(pause);
        var login = new ToolStripMenuItem("Start with Windows") { Checked = LoginItem.Enabled };
        login.Click += (_, _) => { LoginItem.Enabled = !LoginItem.Enabled; RefreshMenu(); };
        menu.Items.Add(login);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit Tidewall", null, (_, _) => ExitThread());
        tray.ContextMenuStrip = menu;
    }

    protected override void ExitThreadCore()
    {
        tray.Visible = false;
        settings?.Close();
        foreach (var w in walls) CloseWall(w);
        tracker.Dispose();
        deskIcons.Dispose();
        explorerWatch.DestroyHandle();
        base.ExitThreadCore();
    }
}

/// "Start with Windows": a value under the current user's Run key.
internal static class LoginItem
{
    const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static bool Enabled
    {
        get => Registry.CurrentUser.OpenSubKey(Key)?.GetValue("Tidewall") is string;
        set
        {
            using var k = Registry.CurrentUser.CreateSubKey(Key);
            if (value) k.SetValue("Tidewall", $"\"{Environment.ProcessPath}\" --background");
            else k.DeleteValue("Tidewall", false);
        }
    }
}

/// A hidden top-level window that hears Explorer's "TaskbarCreated" broadcast (a message-only window never hears it),
/// and a second copy of Tidewall asking this one to show its window.
internal sealed class ExplorerWatch : NativeWindow
{
    public const string Caption = "Tidewall.ExplorerWatch";
    public static readonly uint ShowSettings = Native.RegisterWindowMessage("Tidewall.ShowSettings");
    public static readonly uint Quit = Native.RegisterWindowMessage("Tidewall.Quit");
    static readonly uint taskbarCreated = Native.RegisterWindowMessage("TaskbarCreated");
    readonly Action restarted, show, quit;

    public ExplorerWatch(Action restarted, Action show, Action quit)
    {
        this.restarted = restarted; this.show = show; this.quit = quit;
        CreateHandle(new CreateParams { Caption = Caption });
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == taskbarCreated) restarted();
        else if (m.Msg == ShowSettings) show();
        else if (m.Msg == Quit) quit();
        base.WndProc(ref m);
    }
}
