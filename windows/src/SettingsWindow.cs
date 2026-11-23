using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace Tidewall;

/// The app window: the walls with a live preview, the displays and the settings. The page is the macOS app's
/// (themes/ui), told it's on Windows; messages go to it through tw.receive(…) and come back on the "ui" channel.
internal sealed class SettingsWindow : Form
{
    readonly TidewallApp app;
    readonly WebView2 web = new() { Dock = DockStyle.Fill, DefaultBackgroundColor = Color.FromArgb(245, 245, 243) };
    readonly System.Windows.Forms.Timer usageTimer = new() { Interval = 3000 };
    readonly Usage usage = new();
    string? pendingPage;
    bool loaded;

    public SettingsWindow(TidewallApp app, string? page = null)
    {
        this.app = app;
        pendingPage = page;
        Text = "Tidewall";
        StartPosition = FormStartPosition.CenterScreen;
        // as on the Mac, but never bigger than the screen it opens on (a small laptop screen, a VM)
        var work = Screen.FromPoint(Cursor.Position).WorkingArea;
        ClientSize = new Size(Math.Min(1180, work.Width - 40), Math.Min(780, work.Height - 60));
        MinimumSize = new Size(Math.Min(980, work.Width), Math.Min(680, work.Height));
        // where you left it, as on the Mac (if that's still on a connected screen)
        if (Config.WindowBounds is { } b && Screen.AllScreens.Any(s => s.WorkingArea.IntersectsWith(b) && Rectangle.Intersect(s.WorkingArea, b).Width > 200))
        { StartPosition = FormStartPosition.Manual; Bounds = b; }
        FormClosing += (_, _) => { if (WindowState == FormWindowState.Normal) Config.WindowBounds = Bounds; };
        Theme();
        Microsoft.Win32.SystemEvents.UserPreferenceChanged += ThemeChanged;
        FormClosed += (_, _) => Microsoft.Win32.SystemEvents.UserPreferenceChanged -= ThemeChanged;
        Icon = TidewallApp.AppIcon();
        Controls.Add(web);
        usageTimer.Tick += (_, _) => PushUsage();
        FormClosed += (_, _) => { usageTimer.Dispose(); web.Dispose(); };
        _ = Start();
    }

    void ThemeChanged(object? _, Microsoft.Win32.UserPreferenceChangedEventArgs e) { if (e.Category == Microsoft.Win32.UserPreferenceCategory.General) BeginInvoke(Theme); }

    /// Light or dark as Windows is (the page follows by itself; the frame and the moment before the page paints, here).
    void Theme()
    {
        bool dark = false;
        try { dark = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")?.GetValue("AppsUseLightTheme") is 0; }
        catch (Exception) { }
        web.DefaultBackgroundColor = BackColor = dark ? Color.FromArgb(28, 28, 30) : Color.FromArgb(245, 245, 243);
        int on = dark ? 1 : 0;
        if (IsHandleCreated) Native.DwmSetWindowAttribute(Handle, 20, ref on, sizeof(int));   // DWMWA_USE_IMMERSIVE_DARK_MODE
        else HandleCreated += (_, _) => Native.DwmSetWindowAttribute(Handle, 20, ref on, sizeof(int));
    }

    async Task Start()
    {
        try
        {
            await web.EnsureCoreWebView2Async(await Wallpaper.EnvironmentAsync());
            var core = web.CoreWebView2;
            core.Settings.AreDevToolsEnabled = Args.Has("--devtools");
            core.Settings.IsStatusBarEnabled = false;
            core.Settings.IsZoomControlEnabled = false;
            core.SetVirtualHostNameToFolderMapping(Wallpaper.Host, Config.ThemesRoot, CoreWebView2HostResourceAccessKind.Allow);
            await core.AddScriptToExecuteOnDocumentCreatedAsync(PageScripts.Frame);
            await core.AddScriptToExecuteOnDocumentCreatedAsync(PageScripts.Bridge);
            core.WebMessageReceived += (_, e) => Received(e.TryGetWebMessageAsString());
            core.NewWindowRequested += (_, e) => { e.Handled = true; OpenUrl(e.Uri); };   // links open in the browser, never in here
            core.Navigate($"https://{Wallpaper.Host}/ui/index.html");
            usageTimer.Start();
        }
        catch (Exception e) { Log.Write($"JSERR settings window: {e.Message}"); }
    }

    public void ShowPage(string page)
    {
        if (loaded) Js($"{{\"t\":\"show\",\"page\":{JsonSerializer.Serialize(page)}}}"); else pendingPage = page;
    }

    void Js(string json) { if (web.CoreWebView2 != null) _ = web.CoreWebView2.ExecuteScriptAsync($"window.tw&&tw.receive({json});null"); }
    void Send(JsonObject o) => Js(o.ToJsonString());
    void Toast(string s) => Send(new JsonObject { ["t"] = "toast", ["s"] = s });

    /// A picture of the window's page (the tests).
    public async Task SnapshotAsync(string path)
    {
        if (web.CoreWebView2 == null) return;
        using var f = File.Create(path);
        await web.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, f);
    }

    // MARK: to the page

    public void PushState()
    {
        if (!loaded) return;
        var variants = new JsonObject();
        foreach (var (id, _) in Config.Themes) if (Config.Variant(id) is { } v) variants[id] = v;
        Send(new JsonObject
        {
            ["t"] = "state", ["platform"] = "windows", ["current"] = Config.Theme, ["displays"] = Displays(), ["variants"] = variants,
            ["seed"] = Config.Seed, ["version"] = Config.Version, ["siteQuery"] = Home.Query,
            ["spanThemes"] = new JsonArray(Config.SpanThemes.Select(t => (JsonNode)t).ToArray()),
            ["settings"] = new JsonObject
            {
                ["spanWorlds"] = Config.SpanWorlds, ["login"] = LoginItem.Enabled, ["loginBlocked"] = LoginItem.Blocked,
                ["restWhenIdle"] = Config.IdleMinutes > 0, ["paused"] = Config.Paused, ["fps"] = Config.Fps, ["margin"] = Config.Margin,
                ["autoUpdate"] = Config.AutoUpdate, ["deskIcons"] = Config.DeskIcons, ["deskIconsState"] = "ok",
                ["reactWindows"] = Config.ReactWindows, ["reactStage"] = true, ["reactWidgets"] = true, ["reactCursor"] = Config.ReactCursor,
                ["idleMinutes"] = Config.IdleMinutes > 0 ? Config.IdleMinutes : 0, ["battery"] = Config.Battery,
                ["onBattery"] = app.Power.OnBattery, ["lowPower"] = app.Power.Saver,
            },
            ["update"] = new JsonObject { ["s"] = app.Updates.State, ["v"] = app.Updates.Version, ["err"] = app.Updates.Error, ["checked"] = app.Updates.Checked,
                ["notes"] = app.Updates.Notes, ["auto"] = Config.AutoUpdate, ["admin"] = false },   // (installed per user: never an administrator's password)
            ["newNotes"] = Config.HasNewNotes, ["notesSeen"] = Config.NotesSeen ?? "",
        });
    }

    /// Display ids are their place in Windows' list, from 1 (what the page and the macOS app call a display's id).
    static int IdOf(Display s) => Display.All.ToList().IndexOf(s) + 1;
    static Display? ScreenOf(int id) => Display.All is var all && id >= 1 && id <= all.Count ? all[id - 1] : null;
    double ScaleOf(Display s) => app.Walls.FirstOrDefault(w => w.Screen.Name == s.Name)?.PixelScale ?? DeviceDpi / 96.0;

    JsonArray Displays()
    {
        var list = new JsonArray();
        var screens = Display.All;
        foreach (var s in screens)
        {
            double k = ScaleOf(s); var b = s.Bounds; var theme = Config.ThemeFor(s);
            var world = Config.SpanWorlds && Config.SpanThemes.Contains(theme)
                ? screens.Where(o => Config.ThemeFor(o) == theme).Select(o => (JsonNode)IdOf(o)).ToArray() : [(JsonNode)IdOf(s)];
            list.Add(new JsonObject
            {
                ["id"] = IdOf(s), ["name"] = s.Primary ? "Main display" : $"Display {IdOf(s)}",
                ["x"] = b.X / k, ["y"] = b.Y / k, ["w"] = b.Width / k, ["h"] = b.Height / k,
                ["theme"] = theme, ["own"] = Config.OwnTheme(s.Name) != null, ["main"] = s.Primary, ["world"] = new JsonArray(world),
            });
        }
        return list;
    }

    int? deskShown;   // the display the preview last asked for

    /// The desktop icons changed: the preview redraws them (and the state's "has icons" with it), as on the Mac.
    public void PushDesk()
    {
        if (!loaded || IsDisposed || web.CoreWebView2 == null) return;
        PushState();
        Js($"{{\"t\":\"desktop\",\"d\":{Desktop(deskShown).ToJsonString()},\"icons\":1}}");
    }

    /// A display (the main one by default) and the windows on it now, in its page pixels, so the preview shows your own desktop.
    JsonObject Desktop(int? id = null)
    {
        var s = (id is { } i ? ScreenOf(i) : null) ?? Display.All.FirstOrDefault(d => d.Primary) ?? Display.All[0];
        double k = ScaleOf(s); var f = s.Bounds;
        var windows = new JsonArray();
        foreach (var w in app.Tracker.Windows.Reverse())   // back to front: the page stacks them in order
        {
            if (!w.Bounds.IntersectsWith(f) || w.Owner == "Tidewall") continue;
            windows.Add(new JsonObject { ["x"] = (w.Bounds.X - f.X) / k, ["y"] = (w.Bounds.Y - f.Y) / k, ["w"] = w.Bounds.Width / k,
                ["h"] = w.Bounds.Height / k, ["name"] = w.Name, ["sm"] = false, ["widget"] = false });
        }
        return new JsonObject { ["w"] = f.Width / k, ["h"] = f.Height / k, ["windows"] = windows, ["display"] = IdOf(s), ["notch"] = false,
            ["icons"] = new JsonObject { ["r"] = Local(app.DeskIcons.Icons), ["i"] = Local(app.DeskIcons.Images), ["c"] = Local(app.DeskIcons.Clusters) } };
        JsonArray Local(IEnumerable<Rectangle> rs) => new(rs.Where(r => r.IntersectsWith(f))
            .Select(r => (JsonNode)new JsonArray((r.X - f.X) / k, (r.Y - f.Y) / k, r.Width / k, r.Height / k)).ToArray());
    }

    /// What Tidewall costs (this window shares the walls' browser, so it's counted in, while it's open).
    void PushUsage()
    {
        if (!loaded || web.CoreWebView2 == null) return;
        var u = usage.Measure();
        Js(JsonSerializer.Serialize(new { t = "usage", cpu = u.Cpu, gpu = u.Gpu, mem = u.MemMB }));
    }

    // MARK: from the page

    void Received(string message)
    {
        int sep = message.IndexOf('\u0001');
        if (sep < 0 || message[..sep] != "ui") return;
        JsonObject? o;
        try { o = JsonNode.Parse(message[(sep + 1)..]) as JsonObject; } catch (JsonException) { return; }
        var t = o?["t"]?.GetValue<string>();
        if (o == null || t == null) return;
        switch (t)
        {
            case "hello":
                loaded = true;
                PushState();
                PushUsage();
                Js($"{{\"t\":\"desktop\",\"d\":{Desktop().ToJsonString()}}}");
                Send(new JsonObject { ["t"] = "notes", ["md"] = Config.Changelog });
                if (pendingPage != null) { ShowPage(pendingPage); pendingPage = null; }
                return;
            case "desktop":
                deskShown = o["display"]?.GetValue<int>();
                Js($"{{\"t\":\"desktop\",\"d\":{Desktop(o["display"]?.GetValue<int>()).ToJsonString()}}}");
                return;
            case "log":
                Log.Write($"[ui] {o["s"]?.GetValue<string>()}");
                return;
            case "open":
                OpenUrl(o["url"]?.GetValue<string>());
                return;
            case "report":
                Report();
                return;
            case "quit":
                app.ExitThread();
                return;
            case "checkUpdate":
                _ = app.Updates.Check(manual: true);
                return;
            case "installUpdate":
                app.Updates.Install();
                return;
        }
        if (!Change(t, o)) { Log.Write($"[ui] unknown message {t}"); return; }
        PushState();
        app.RefreshMenu();
    }

    bool Change(string t, JsonObject o)
    {
        switch (t)
        {
            case "notesSeen":
                Config.NotesSeen = Config.Version;
                break;
            case "apply":
                if (o["theme"]?.GetValue<string>() is { } id && Config.IsTheme(id)) { Config.ClearDisplayThemes(); Config.Theme = id; app.ReloadStale("theme chosen"); }
                break;
            case "applyDisplay":
                var theme = o["theme"]?.GetValue<string>();
                if (theme != null && !Config.IsTheme(theme)) break;
                if (o["display"]?.GetValue<int>() is not int d || ScreenOf(d) is not { } s) { Toast("That display isn't connected any more."); break; }
                Config.SetOwnTheme(s.Name, theme);
                app.ReloadStale("theme chosen");
                break;
            case "variant":
                if (o["theme"]?.GetValue<string>() is { } vt && o["id"]?.GetValue<string>() is { } v && Config.IsTheme(vt)) { Config.SetVariant(vt, v); app.ReloadStale("variant chosen"); }
                break;
            case "set":
                Set(o["key"]?.GetValue<string>() ?? "", o["value"]);
                break;
            case "reload":
                app.RebuildWalls();
                break;
            default:
                return false;
        }
        return true;
    }

    static bool On(JsonNode? v, bool fallback) { try { return v?.GetValue<bool>() ?? fallback; } catch (InvalidOperationException) { return fallback; } }
    static double Num(JsonNode? v, double fallback) { try { return v?.GetValue<double>() ?? fallback; } catch (InvalidOperationException) { return fallback; } }

    void Set(string key, JsonNode? v)
    {
        switch (key)
        {
            case "login":
                // switched off in Windows' Startup apps: only the user can turn it back on there, so that's where it opens
                if (On(v, false) && LoginItem.Blocked) Process.Start(new ProcessStartInfo("ms-settings:startupapps") { UseShellExecute = true });
                else LoginItem.Enabled = On(v, false);
                PushState();
                break;
            case "restWhenIdle": Config.IdleMinutes = On(v, true) ? Config.IdleLast : 0; break;
            case "idleMinutes": Config.IdleMinutes = Num(v, 3); break;
            case "spanWorlds": Config.SpanWorlds = On(v, true); app.Dispatch(false); app.RefreshMenu(); break;   // the walls are told their new world: none starts again
            case "paused": Config.Paused = On(v, false); app.Dispatch(false); break;
            case "fps": Config.Fps = Num(v, 0); app.RebuildWalls(); break;
            case "margin": Config.Margin = Num(v, 140); app.Dispatch(false); break;
            case "reactWindows": Config.ReactWindows = On(v, true); app.Dispatch(false); break;
            case "reactCursor":
                Config.ReactCursor = On(v, true);
                if (!Config.ReactCursor) foreach (var w in app.Walls) w.CursorOff();
                app.Dispatch(false);
                break;
            case "battery": Config.Battery = (int)Num(v, 0); app.CheckPower(); break;
            case "autoUpdate": Config.AutoUpdate = On(v, true); if (Config.AutoUpdate) _ = app.Updates.Check(); break;
            case "deskIcons": Config.DeskIcons = On(v, true); app.DeskIcons.Read(); break;
        }
    }

    static void OpenUrl(string? s)
    {
        if (s == null || !Uri.TryCreate(s, UriKind.Absolute, out var u) || (u.Scheme != "https" && u.Scheme != "http")) return;
        try { Process.Start(new ProcessStartInfo(u.ToString()) { UseShellExecute = true }); } catch (Exception e) { Log.Write($"could not open {u}: {e.Message}"); }
    }

    /// The end of the log on the clipboard (user names taken out), and a filled-in GitHub issue to paste it into.
    void Report()
    {
        try
        {
            var lines = File.Exists(Log.Path) ? File.ReadLines(Log.Path).TakeLast(200) : [];
            var text = string.Join(Environment.NewLine, lines).Replace(Environment.UserName, "<user>");
            Clipboard.SetText($"Tidewall {Config.Version} on Windows {Environment.OSVersion.Version}{Environment.NewLine}{text}");
            OpenUrl("https://github.com/Keshav-Madhav/tidewall/issues/new?title=" + Uri.EscapeDataString($"Windows {Config.Version}: "));
            Toast("The end of Tidewall’s log is on your clipboard: paste it into the issue if you’re happy to share it.");
        }
        catch (Exception e) { Log.Write($"report: {e.Message}"); }
    }
}
