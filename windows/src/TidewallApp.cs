using Microsoft.Win32;

namespace Tidewall;

/// Owns the walls (one per display), the window tracker that feeds them, the tray menu, and everything that decides
/// whether they draw: a maximised or full-screen app over a display, the screen locked, the PC asleep, nobody at it,
/// battery, the user's pause. Away a while, or hidden a while behind a window, a wall becomes a still picture and lets
/// go of its memory (as on the Mac).
internal sealed class TidewallApp : ApplicationContext
{
    readonly Control loop = new();
    readonly WindowTracker tracker;
    readonly DeskIcons deskIcons;
    readonly Locator locator;
    readonly NotifyIcon tray;
    readonly System.Windows.Forms.Timer clock = new() { Interval = 1000 };
    readonly System.Windows.Forms.Timer pointer = new() { Interval = 16 };
    readonly List<Wallpaper> walls = [];
    DesktopLayer.Host? layer;
    bool locked, idle, asleep, displaysOff, released;
    PowerState power = PowerState.Current();
    DateTime? restSince;
    readonly Dictionary<Wallpaper, DateTime> coveredSince = [];
    int ticks;
    public PowerState Power => power;
    bool Resting => Config.Paused || locked || idle || asleep || displaysOff || power.Paused;
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
        tracker.Released += deskIcons.Released;
        Updates = new Updater();
        Updates.Changed += () => { settings?.PushState(); RebuildMenu(); };
        deskIcons.Changed += () =>
        {
            foreach (var w in walls) if (w.Ready) w.SendDeskIcons(deskIcons, WorldFor(w));
            settings?.PushDesk();                                          // (the preview's desk shows them too)
            retune.Stop(); retune.Start();                                 // Wind Tunnel's default follows whether there are icons
        };
        retune.Tick += (_, _) => { retune.Stop(); ReloadStale("desktop icons came or went"); };
        tray = new NotifyIcon { Icon = AppIcon(), Text = "Tidewall", Visible = !Args.Has("--test") };
        tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) ShowSettings(); };   // a click opens the window; right-click, the menu
        if (Config.NotesSeen == null && !Config.Welcomed) Config.NotesSeen = Config.Version;   // a fresh install: nothing to announce
        RebuildMenu();
        BuildWalls();
        // where you are, for the walls that draw the real sky (Windows asks once); a move redraws them
        locator = new Locator(() => loop.BeginInvoke(() => { foreach (var w in walls.ToList()) ReplaceWall(w, "you moved"); RefreshMenu(); }));
        // opened by hand (Start menu, the desktop shortcut, the installer's last step), or for the first time ever: the window,
        // as on the Mac; started at login (--background) it stays out of the way
        if (Args.Has("--settings")) loop.BeginInvoke(() => ShowSettings(Args.Value("--settings")));
        else if (!Args.Has("--test") && (!Args.Has("--background") || !Config.Welcomed)) loop.BeginInvoke(() => { ShowSettings(); Config.Welcomed = true; });

        // (the menu's display list and the window's preview follow the displays too, as on the Mac)
        rebuildSoon.Tick += (_, _) => { rebuildSoon.Stop(); BuildWalls(!rebuildWithoutHandOver); rebuildWithoutHandOver = false; RefreshMenu(); settings?.PushDesk(); };
        SystemEvents.DisplaySettingsChanged += (_, _) => loop.BeginInvoke(() => RebuildSoon("displays changed"));
        // Explorer restarted (it crashed, or someone restarted it): the desktop window the walls lived in went with it.
        // It says so to every top-level window ("TaskbarCreated"); the walls are made again in the new one.
        explorerWatch = new ExplorerWatch(() => loop.BeginInvoke(() => RebuildSoon("Explorer restarted", handOver: false)), () => loop.BeginInvoke(() => ShowSettings()),
            () => loop.BeginInvoke(() => { Log.Write("asked to quit (being uninstalled)"); ExitThread(); }),
            // the displays went dark with the PC still awake (the power plan's "turn off the display"): nobody can see
            // the walls, so they rest, as on the Mac; it's also a good moment to put a waiting update in
            on => loop.BeginInvoke(() =>
            {
                if (displaysOff == !on) return;
                displaysOff = !on; Log.Write(on ? "displays on" : "displays off");
                if (!on) Updates.Locked(); else CheckGPUContexts();
                Dispatch(false);
            }));
        SystemEvents.SessionSwitch += (_, e) =>
        {
            if (e.Reason is SessionSwitchReason.SessionLock or SessionSwitchReason.ConsoleDisconnect) { locked = true; Updates.Locked(); }
            if (e.Reason is SessionSwitchReason.SessionUnlock or SessionSwitchReason.ConsoleConnect) { locked = false; CheckGPUContexts(); }
            loop.BeginInvoke(() => Dispatch(false));
        };
        SystemEvents.PowerModeChanged += (_, e) => loop.BeginInvoke(() =>
        {
            if (e.Mode == PowerModes.Suspend) { asleep = true; Log.Write("asleep"); }
            else if (e.Mode == PowerModes.Resume) { asleep = false; Log.Write("awake"); CheckGPUContexts(); locator.Look(); }
            CheckPower(); Dispatch(false);
        });
        Wallpaper.SetPace(power.Pace, walls);
        Log.Write($"power: {(power.OnBattery ? "battery" : "mains")}{(power.Saver ? ", saver" : "")}, pace {power.Pace}{(power.Paused ? ", paused" : "")}");
        menuTimer.Tick += (_, _) => RefreshUsageLines();
        usageMarks.Tick += (_, _) => menuUsage.Mark(settings is { IsDisposed: false } s ? s.OwnProcesses : null);
        usageMarks.Start(); menuUsage.Mark();
        clock.Tick += (_, _) => { CheckIdle(); if (++ticks % 10 == 0) CheckPower(); CheckAway(); CheckCovered(); };
        clock.Start();
        pointer.Tick += (_, _) => FollowPointer();
        Log.Write($"Tidewall {Config.Version} on Windows {Environment.OSVersion.Version}; themes {Config.ThemesRoot}{(Args.Has("--restarted") ? " (restarted after a crash)" : "")}");
        // crashed or hung (after its first minute): Windows starts it again, quietly, as the Mac's login agent does. A
        // quit, an update or the uninstaller stopping it isn't a crash. (Not for a Windows Update restart: that's login's.)
        if (!Args.Has("--test")) Native.RegisterApplicationRestart("--background --restarted", 4 | 8);   // RESTART_NO_PATCH | RESTART_NO_REBOOT
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

    /// Every wall made again. `handOver`: each new wall starts beneath the one it replaces, which stays (its picture
    /// showing) until the new one is ready, so the desktop never shows bare between them; not when the old ones are
    /// already gone (Explorer restarted).
    void BuildWalls() => BuildWalls(true);

    void BuildWalls(bool handOver)
    {
        var old = walls.ToList();
        walls.Clear();
        if (!handOver) { foreach (var w in old) CloseWall(w); old.Clear(); }
        coveredSince.Clear(); released = false;
        pointerWall = null;                                               // (it was one of those)
        layer = DesktopLayer.Find();
        Log.Write($"desktop layer: {(layer.InsideProgman ? "inside Progman (24H2)" : "WorkerW")} {layer.Parent}");
        foreach (var screen in Display.All)
        {
            var wall = new Wallpaper(screen, Config.ThemeFor(screen)) { Replacing = old.FirstOrDefault(o => o.Screen.Name == screen.Name) };
            Watch(wall);
            walls.Add(wall);
            _ = StartWall(wall);
        }
        // a replaced wall whose successor never came up (a display gone, a page that failed) goes after 20 s anyway
        foreach (var o in old.Where(o => !walls.Any(w => w.Replacing == o))) CloseWall(o);
        var leftovers = old.Where(o => walls.Any(w => w.Replacing == o)).ToList();
        if (leftovers.Count > 0) _ = Task.Delay(20000).ContinueWith(_ => loop.BeginInvoke(() => { foreach (var o in leftovers) if (!o.IsDisposed) CloseWall(o); }));
        tracker.MinLookMs = Math.Max(4, 1000 / Math.Max(1, walls.Max(w => w.RefreshRate())));
    }

    async Task StartWall(Wallpaper wall)
    {
        try { await wall.StartAsync(layer!); }
        catch (Exception e) when (wall.IsDisposed) { Log.Write($"a {wall.Theme} wall closed while it started ({e.GetType().Name})"); }   // (replaced by a newer one)
        catch (Exception e) { Log.Write($"JSERR could not start the {wall.Theme} wall: {e.Message}"); }
    }

    /// One world across the displays that show a spanning wall, measured in points so displays at different scales
    /// still join up (a laptop at 150% beside a monitor at 100%), as on the Mac.
    IReadOnlyList<WorldPart>? WorldFor(Wallpaper w)
    {
        if (!Config.SpanWorlds || !Config.SpanThemes.Contains(w.Theme)) return null;
        var same = walls.Where(o => o.Theme == w.Theme).Select(o => (o.Screen, o.PixelScale)).ToList();
        return same.Count > 1 ? World.Layout(same) : null;
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
            if (covered) coveredSince.TryAdd(w, DateTime.UtcNow); else coveredSince.Remove(w);
            bool rest = Resting || covered;
            // windows off: it carries on as if they weren't there. A wall that comes up resting lays itself out round the
            // windows once first, then rests (as on the Mac), rather than resting on an empty desk
            bool first = !w.LaidOut;
            if (!rest || live || first) w.SendWindows(Config.ReactWindows ? windows : Array.Empty<TrackedWindow>(), live);
            // (its first layout gets 1.5 s to draw before it rests, as on the Mac: paused at once it froze half-drawn)
            if (rest && first) _ = Task.Delay(1500).ContinueWith(_ => loop.BeginInvoke(() => Dispatch(false)));
            else w.SetPaused(rest);
        }
        // nothing to follow the pointer for: no ticks at all (it ran 60 times a second all day, paused or not)
        pointer.Enabled = walls.Any(w => w.Ready && !w.Paused && w.WantsCursor) && !Resting;
        tracker.Resting = deskIcons.Resting = Resting;
    }

    readonly ExplorerWatch explorerWatch;
    readonly System.Windows.Forms.Timer rebuildSoon = new() { Interval = 800 };

    /// Every wall again, a moment from now: the reasons come in bursts (Explorer's broadcast and the desktop window
    /// going; a display change in several steps), and one rebuild serves them all.
    void RebuildSoon(string why, bool handOver = true)
    {
        Log.Write($"{why}: the walls again");
        if (!handOver) rebuildWithoutHandOver = true;
        rebuildSoon.Stop(); rebuildSoon.Start();
    }
    bool rebuildWithoutHandOver;

    void CheckIdle()
    {
        if (layer != null && !Native.IsWindow(layer.Parent) && !rebuildSoon.Enabled) RebuildSoon("the desktop window is gone", handOver: false);   // (in case the broadcast was missed)
        bool now = Config.IdleMinutes > 0 && Native.IdleSeconds() > Config.IdleMinutes * 60;
        if (now == idle) return;
        idle = now;
        Log.Write(idle ? "idle: resting" : "input: awake");
        Dispatch(false);
    }

    /// On battery (or Battery saver): Settings ▸ On battery says what the walls do; checked every 10 s and on any change.
    public void CheckPower()
    {
        var now = PowerState.Current();
        if (now == power) return;
        Log.Write($"power: {(now.OnBattery ? "battery" : "mains")}{(now.Saver ? ", saver" : "")}, pace {now.Pace}{(now.Paused ? ", paused" : "")}");
        power = now;
        Wallpaper.SetPace(now.Pace, walls);
        Dispatch(false);
        settings?.PushState();
    }

    /// Away a while (paused, locked, asleep or paused on battery for 90 s; idle at the PC for 10 minutes): every wall
    /// becomes a still picture and lets go of its memory, until you're back.
    void CheckAway()
    {
        bool away = Config.Paused || locked || asleep || displaysOff || power.Paused;
        if (away || idle)
        {
            restSince ??= DateTime.UtcNow;
            if (!released && (DateTime.UtcNow - restSince.Value).TotalSeconds >= (away ? 90 : 600))
            {
                released = true;
                Log.Write("away a while: the walls let go");
                foreach (var w in walls) _ = w.FreezeAsync();
            }
        }
        else
        {
            restSince = null;
            if (released) { Log.Write("back: the walls again"); BuildWalls(); }
        }
    }

    /// A wall hidden 30 s behind a maximised or full-screen window becomes a still picture; uncovered, it's made again.
    void CheckCovered()
    {
        if (released) return;
        var rects = tracker.Windows.Select(t => t.Bounds).ToList();
        foreach (var w in walls.ToList())
        {
            if (w.Frozen) { if (!Covered.IsCovered(w.Screen.WorkingArea, rects)) ReplaceWall(w); continue; }
            // as on the Mac: under a full-screen app (the taskbar hidden too) it lets go after 15 s, under maximised windows 30 s
            double after = Covered.IsCovered(w.Screen.Bounds, rects) ? 15 : 30;
            if (coveredSince.TryGetValue(w, out var since) && (DateTime.UtcNow - since).TotalSeconds >= after) { coveredSince.Remove(w); _ = w.FreezeAsync(); }
        }
    }

    readonly System.Windows.Forms.Timer retune = new() { Interval = 2000 };

    /// Only the walls a change touches start again, as on the Mac (a theme or variant chosen for one display, or a
    /// default that moved): the others carry on undisturbed.
    public void ReloadStale(string why)
    {
        foreach (var w in walls.Where(w => w.Theme != Config.ThemeFor(w.Screen) || w.LoadedVariant != Config.Variant(w.Theme)).ToList())
            ReplaceWall(w, why);
        RefreshMenu();
    }

    /// A few seconds after waking, unlocking or the displays coming on (monitors take a moment), any wall left without its
    /// WebGL context starts again, as on the Mac. Pages usually notice by themselves; this is the safety net.
    void CheckGPUContexts() => _ = Task.Delay(4000).ContinueWith(_ => loop.BeginInvoke(async () =>
    {
        if (released) return;
        foreach (var w in walls.Where(w => w.Ready && !w.Frozen).ToList())
        {
            string lost;
            try { lost = await w.AskAsync("return !!(window.__twGLLost && window.__twGLLost())"); } catch (Exception) { continue; }
            if (lost.Contains("true") && walls.Contains(w)) ReplaceWall(w, "lost its GPU context");
        }
    }));

    /// One wall made again (its still picture replaced by the live page, or a new theme or variant).
    void ReplaceWall(Wallpaper old, string why = "uncovered")
    {
        int i = walls.IndexOf(old);
        if (i < 0) return;
        if (pointerWall == old) pointerWall = null;
        coveredSince.Remove(old);
        var wall = new Wallpaper(old.Screen, Config.ThemeFor(old.Screen)) { Replacing = old };
        Watch(wall);
        walls[i] = wall;
        Log.Write($"{why}: the {wall.Theme} wall again on {wall.Screen.Name}");
        _ = StartWall(wall);
    }

    /// A new wall: once its page is ready the walls are told the desk, and the one it replaces goes.
    void Watch(Wallpaper wall) => wall.BecameReady += w =>
    {
        if (w.Replacing is { } r) { w.Replacing = null; if (!r.IsDisposed) CloseWall(r); }
        Dispatch(false);
    };

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

    // MARK: tray menu (the Mac's menu-bar menu)

    readonly Usage menuUsage = new();
    readonly System.Windows.Forms.Timer menuTimer = new() { Interval = 2000 };
    readonly ToolStripMenuItem[] usageLines = [new("CPU  –") { Enabled = false }, new("GPU  –") { Enabled = false }, new("Memory  –") { Enabled = false }, new("") { Enabled = false, Visible = false }];
    readonly System.Windows.Forms.Timer usageMarks = new() { Interval = 15000 };

    static string DisplayName(Display d, int i) => DisplayNames.Of(d) ?? (d.Primary ? "Main display" : $"Display {i + 1}");
    static string LabelOf(string id) => Config.Label(id);

    /// "Name · tier": the name, and the tier quietly on the right.
    static ToolStripMenuItem ThemeItem(string label, bool on, Action pick)
    {
        var parts = label.Split(" · ");
        var it = new ToolStripMenuItem(parts[0]) { Checked = on, ShortcutKeyDisplayString = parts.Length > 1 ? parts[1] : null };
        it.Click += (_, _) => pick();
        return it;
    }

    void RebuildMenu()
    {
        var menu = new ContextMenuStrip();
        var bold = new Font(menu.Font, FontStyle.Bold);
        // notices: what's new, an update
        if (Config.HasNewNotes)
        {
            menu.Items.Add(new ToolStripMenuItem($"What’s New in Tidewall {Config.Version}…", null, (_, _) => ShowSettings("whatsnew")) { Font = bold });
            menu.Items.Add(new ToolStripSeparator());
        }
        if (Updates.State == "ready") { menu.Items.Add(new ToolStripMenuItem($"Restart to Update to {Updates.Version}", null, (_, _) => Updates.Install()) { Font = bold }); menu.Items.Add(new ToolStripSeparator()); }
        else if (Updates.State == "downloading") { menu.Items.Add(new ToolStripMenuItem($"Downloading Tidewall {Updates.Version}…") { Enabled = false }); menu.Items.Add(new ToolStripSeparator()); }
        // what it costs, live while the menu is open
        foreach (var l in usageLines) menu.Items.Add(l);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Open Tidewall…", null, (_, _) => ShowSettings()) { Font = bold });
        menu.Items.Add(new ToolStripSeparator());
        // the wall per display, and for all of them
        var displays = Display.All;
        bool several = displays.Count > 1;
        if (several)
            for (int i = 0; i < displays.Count; i++)
            {
                var d = displays[i]; bool own = Config.OwnTheme(d.Name) != null;
                var sub = new ToolStripMenuItem($"{DisplayName(d, i)} — {LabelOf(Config.ThemeFor(d))}");
                sub.DropDownItems.Add(ThemeItem(d.Primary ? $"Default ({LabelOf(Config.Theme)})" : $"Same as Main ({LabelOf(Config.Theme)})", !own, () => { Config.SetOwnTheme(d.Name, null); ReloadStale("theme chosen"); }));
                foreach (var (id, label) in Config.Themes) sub.DropDownItems.Add(ThemeItem(label, own && Config.ThemeFor(d) == id, () => { Config.SetOwnTheme(d.Name, id); ReloadStale("theme chosen"); }));
                menu.Items.Add(sub);
            }
        bool anyOwn = displays.Any(d => Config.OwnTheme(d.Name) != null);
        var all = new ToolStripMenuItem(several ? "All Displays" : "Wall");
        foreach (var (id, label) in Config.Themes)
            all.DropDownItems.Add(ThemeItem(label, Config.Theme == id && !anyOwn, () => { Config.ClearDisplayThemes(); Config.Theme = id; ReloadStale("theme chosen"); }));
        menu.Items.Add(all);
        menu.Items.Add(new ToolStripSeparator());
        // the switches
        menu.Items.Add(new ToolStripMenuItem("Pause", null, (_, _) => { Config.Paused = !Config.Paused; Dispatch(false); RefreshMenu(); }) { Checked = Config.Paused });
        menu.Items.Add(new ToolStripMenuItem("Rest when idle", null, (_, _) => { Config.IdleMinutes = Config.IdleMinutes > 0 ? 0 : Config.IdleLast; RefreshMenu(); }) { Checked = Config.IdleMinutes > 0 });
        menu.Items.Add(new ToolStripMenuItem("Start with Windows", null, (_, _) => { LoginItem.Enabled = !LoginItem.Enabled; RefreshMenu(); }) { Checked = LoginItem.Enabled });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Check for Updates…", null, (_, _) => { _ = Updates.Check(manual: true); ShowSettings("about"); });
        menu.Items.Add("Quit Tidewall", null, (_, _) => ExitThread());
        menu.Opening += (_, _) =>
        {
            menuUsage.Measure();                                          // a baseline: figures from 2 s on
            usageLines[0].Text = "CPU      measuring…"; usageLines[1].Text = "GPU      measuring…"; usageLines[2].Text = "Memory   measuring…";
            menuTimer.Start();
        };
        menu.Closed += (_, _) => menuTimer.Stop();
        var old = tray.ContextMenuStrip;
        tray.ContextMenuStrip = menu;
        old?.Dispose();
    }

    /// Tests: the tray menu, open where the taskbar's tray would show it.
    public void ShowMenuForTest()
    {
        var wa = Screen.PrimaryScreen!.WorkingArea;
        tray.ContextMenuStrip?.Show(new Point(wa.Right - 20, wa.Bottom - 10), ToolStripDropDownDirection.AboveLeft);
    }

    void RefreshUsageLines()
    {
        // the walls' cost (over the last minute, once there is one) and, apart, the open window's, as on the Mac
        var window = settings is { IsDisposed: false } s ? s.OwnProcesses : null;
        var u = menuUsage.Measure(window);
        bool minute = u.AvgCpu >= 0;
        usageLines[0].Text = $"CPU      {(minute ? u.AvgCpu : u.Cpu):0.0}%{(minute ? "  last minute" : "")}";
        usageLines[1].Text = u.Gpu < 0 ? "GPU      –" : $"GPU      {u.Gpu:0.0}%{(window is { Count: > 0 } ? "  incl. window" : "")}";
        usageLines[2].Text = $"Memory   {u.MemMB:0} MB";
        { usageLines[3].Text = u.WindowMemMB > 0 ? $"+ window {u.WindowMemMB:0} MB, freed on close" : ""; usageLines[3].Visible = u.WindowMemMB > 0; }
    }

    protected override void ExitThreadCore()
    {
        tray.Visible = false;
        settings?.Close();
        foreach (var w in walls) CloseWall(w);
        tracker.Dispose();
        deskIcons.Dispose();
        explorerWatch.Close();
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

    /// Switched off for Tidewall in Settings ▸ Apps ▸ Startup (or Task Manager's Startup apps): Windows keeps the Run
    /// entry and marks it here, an odd first byte meaning off. As on the Mac, the switch then shows off and says where.
    public static bool Blocked
    {
        get
        {
            try
            {
                return Enabled && Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run")
                    ?.GetValue("Tidewall") is byte[] { Length: > 0 } b && (b[0] & 1) == 1;
            }
            catch (Exception) { return false; }
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
    readonly Action<bool> displays;
    readonly IntPtr displayNote;
    static Guid consoleDisplayState = new("6FE69556-704A-47A0-8F24-C28D936FDA47");   // GUID_CONSOLE_DISPLAY_STATE

    public ExplorerWatch(Action restarted, Action show, Action quit, Action<bool> displays)
    {
        this.restarted = restarted; this.show = show; this.quit = quit; this.displays = displays;
        CreateHandle(new CreateParams { Caption = Caption });
        displayNote = Native.RegisterPowerSettingNotification(Handle, ref consoleDisplayState, 0);
    }

    public void Close() { if (displayNote != IntPtr.Zero) Native.UnregisterPowerSettingNotification(displayNote); DestroyHandle(); }

    protected override void WndProc(ref Message m)
    {
        const int WM_POWERBROADCAST = 0x218, PBT_POWERSETTINGCHANGE = 0x8013;
        if (m.Msg == WM_POWERBROADCAST && (int)m.WParam == PBT_POWERSETTINGCHANGE && m.LParam != IntPtr.Zero)
        {
            // POWERBROADCAST_SETTING: the setting's GUID, the data's length, then the data: 0 off, 1 on, 2 dimmed
            var setting = System.Runtime.InteropServices.Marshal.PtrToStructure<Guid>(m.LParam);
            if (setting == consoleDisplayState) displays(System.Runtime.InteropServices.Marshal.ReadInt32(m.LParam, 20) != 0);
        }
        else if (m.Msg == taskbarCreated) restarted();
        else if (m.Msg == ShowSettings) show();
        else if (m.Msg == Quit) quit();
        base.WndProc(ref m);
    }
}
