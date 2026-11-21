using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace Tidewall;

/// One display's wall: a borderless window in the desktop layer, behind the icons, showing a theme page in WebView2.
/// The page hears where the windows are (in its device pixels) and says when it's ready.
internal sealed class Wallpaper : Form
{
    const string Host = "tidewall.local";
    static CoreWebView2Environment? environment;

    readonly WebView2 web = new() { Dock = DockStyle.Fill, DefaultBackgroundColor = Color.FromArgb(239, 228, 204) };
    readonly string theme;
    public Screen Screen { get; }
    public Rectangle Frame => Screen.Bounds;
    public bool Ready { get; private set; }
    public bool Paused { get; private set; }
    public bool WantsCursor { get; private set; } = true;
    public string Theme => theme;
    public event Action<Wallpaper>? BecameReady;

    string lastWindows = "", lastIcons = "", lastDesk = "";

    public Wallpaper(Screen screen, string theme)
    {
        Screen = screen;
        this.theme = theme;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        Bounds = screen.Bounds;
        BackColor = web.DefaultBackgroundColor;
        Controls.Add(web);
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var p = base.CreateParams;
            p.ExStyle |= (int)(Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE);   // never in Alt+Tab, never takes focus
            return p;
        }
    }

    public async Task StartAsync(DesktopLayer.Host layer)
    {
        Show();
        DesktopLayer.Attach(Handle, layer, Screen.Bounds);

        environment ??= await CoreWebView2Environment.CreateAsync(null, Path.Combine(Config.DataDir, "WebView2"),
            new CoreWebView2EnvironmentOptions("--autoplay-policy=no-user-gesture-required --disable-features=msSmartScreenProtection"));
        await web.EnsureCoreWebView2Async(environment);
        var core = web.CoreWebView2;
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.Settings.AreDevToolsEnabled = Args.Has("--devtools");
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.IsZoomControlEnabled = false;
        core.Settings.AreBrowserAcceleratorKeysEnabled = false;
        core.SetVirtualHostNameToFolderMapping(Host, Config.ThemesRoot, CoreWebView2HostResourceAccessKind.Allow);

        await core.AddScriptToExecuteOnDocumentCreatedAsync(PageScripts.Bridge);
        await core.AddScriptToExecuteOnDocumentCreatedAsync(PageScripts.Early(Config.Fps, maxHz: RefreshRate()));
        core.DOMContentLoaded += (_, _) => _ = core.ExecuteScriptAsync(PageScripts.Late);
        core.WebMessageReceived += (_, e) => Received(e.TryGetWebMessageAsString());
        await WatchConsole(core);
        core.ProcessFailed += (_, e) => { Log.Write($"[{theme}] web process failed ({e.ProcessFailedKind}); reloading"); Ready = false; core.Reload(); };

        var variant = Config.Variant(theme) is { } v ? "&v=" + Uri.EscapeDataString(v) : "";
        core.Navigate($"https://{Host}/{Config.Page(theme)}.html?wallpaper=1{variant}");
    }

    public int RefreshRate()
    {
        // the display's refresh rate, for the page's frame pacer (it draws at most this fast while things move)
        var mode = new DEVMODE { dmSize = (short)System.Runtime.InteropServices.Marshal.SizeOf<DEVMODE>() };
        return EnumDisplaySettings(Screen.DeviceName, -1, ref mode) && mode.dmDisplayFrequency > 1 ? mode.dmDisplayFrequency : 60;
    }

    /// The page's console errors and uncaught exceptions, in Tidewall's log (a wall that fails quietly is still caught).
    async Task WatchConsole(CoreWebView2 core)
    {
        await core.CallDevToolsProtocolMethodAsync("Runtime.enable", "{}");
        core.GetDevToolsProtocolEventReceiver("Runtime.exceptionThrown").DevToolsProtocolEventReceived += (_, e) =>
            Log.Write($"[{theme}] JSERR exception {Clip(e.ParameterObjectAsJson)}");
        core.GetDevToolsProtocolEventReceiver("Runtime.consoleAPICalled").DevToolsProtocolEventReceived += (_, e) =>
        {
            if (e.ParameterObjectAsJson.Contains("\"type\":\"error\"") || e.ParameterObjectAsJson.Contains("\"type\":\"warning\""))
                Log.Write($"[{theme}] console {Clip(e.ParameterObjectAsJson)}");
        };
    }

    static string Clip(string s) => s.Length > 600 ? s[..600] + "…" : s;

    void Received(string message)
    {
        int sep = message.IndexOf('\u0001');
        var body = sep >= 0 ? message[(sep + 1)..] : message;
        switch (body)
        {
            case "ready":
                Ready = true;
                lastWindows = lastIcons = lastDesk = "";
                SendDesk();
                Send($"{{\"t\":\"me\",\"seed\":{Config.Seed}}}");
                if (Paused) Send("{\"t\":\"pause\",\"v\":true}");
                Log.Write($"[{theme}] ready on {Screen.DeviceName} {Screen.Bounds} scale {PixelScale:0.##}");
                BecameReady?.Invoke(this);
                break;
            case "nocursor":
                WantsCursor = false;
                break;
            case "patched":
                break;
            default:
                if (body.StartsWith("JSERR") || body.StartsWith("NOTE")) Log.Write($"[{theme}] {body}");
                break;
        }
    }

    public void Send(string json, bool live = false)
    {
        if (!Ready) return;
        var literal = JsonSerializer.Serialize(json);
        _ = web.CoreWebView2.ExecuteScriptAsync($"window.__live={(live ? "true" : "false")};window.__hostSend({literal});window.__live=false;");
    }

    /// This display's scale (its device pixels per page pixel).
    public double PixelScale => DeviceDpi / 96.0;

    /// Where this display sits among the others, in page pixels.
    public void SendDesk(IReadOnlyList<Screen>? world = null)
    {
        var frames = (world ?? [Screen]).Select(s => s.Bounds).ToList();
        var u = frames.Aggregate(frames[0], Rectangle.Union);
        double k = PixelScale;
        int Px(double v) => (int)Math.Round(v / k);
        var fr = string.Join(",", frames.Select(f => $"[{Px(f.X - u.X)},{Px(f.Y - u.Y)},{Px(f.Width)},{Px(f.Height)}]"));
        var me = Screen.Bounds;
        var main = (world ?? [Screen]).FirstOrDefault(s => s.Primary)?.Bounds ?? me;
        int i = frames.IndexOf(me);
        var msg = $"{{\"t\":\"desk\",\"fr\":[{fr}],\"x\":{Px(me.X - u.X)},\"y\":{Px(me.Y - u.Y)},\"w\":{Px(me.Width)},\"h\":{Px(me.Height)}," +
                  $"\"uw\":{Px(u.Width)},\"uh\":{Px(u.Height)},\"i\":{Math.Max(0, i)},\"n\":{frames.Count}," +
                  $"\"mx\":{Px(main.X + main.Width / 2.0 - u.X)},\"my\":{Px(main.Y + main.Height / 2.0 - u.Y)},\"mw\":{Px(main.Width)},\"mh\":{Px(main.Height)}}}";
        if (msg == lastDesk) return;
        lastDesk = msg;
        Send(msg);
    }

    /// The windows over this display (screen pixels in), as the page wants them: its own device pixels.
    public void SendWindows(IReadOnlyList<TrackedWindow> windows, bool live)
    {
        var f = Frame;
        var mine = windows.Where(w => w.Bounds.IntersectsWith(f)).ToList();
        string Box(Rectangle r) => $"[{r.Left - f.Left},{r.Top - f.Top},{r.Right - f.Left},{r.Bottom - f.Top}]";
        var names = JsonSerializer.Serialize(mine.Select(w => w.Owner).ToArray());
        var wins = $"{{\"t\":\"windows\",\"live\":{(live ? "true" : "false")},\"r\":[{string.Join(",", mine.Select(w => Box(w.Bounds)))}],\"n\":{names},\"sm\":[{string.Join(",", mine.Select(_ => "0"))}]}}";
        if (wins != lastWindows) { lastWindows = wins; Send(wins, live); }
        int m = (int)Math.Round(Config.Margin * PixelScale);   // the room the scene keeps around each window, in page pixels
        var icons = $"{{\"t\":\"icons\",\"vis\":true,\"r\":[{string.Join(",", mine.Select(w => Box(Rectangle.Inflate(w.Bounds, m, m))))}]}}";
        if (icons != lastIcons) { lastIcons = icons; Send(icons, live); }
    }

    public void SetPaused(bool on)
    {
        if (on == Paused) return;
        Paused = on;
        Send(on ? "{\"t\":\"pause\",\"v\":true}" : "{\"t\":\"pause\",\"v\":false}");
    }

    public void SendCursor(Point screen, bool overWindow)
    {
        if (!WantsCursor || Paused) return;
        // over a window or the taskbar you're working, not watching: 10 messages a second, not 60 (as on the Mac)
        overWindow |= !Screen.WorkingArea.Contains(screen);
        long now = Environment.TickCount64;
        if (overWindow && wasOverWindow && now - lastOverSend < 100) return;
        wasOverWindow = overWindow;
        if (overWindow) lastOverSend = now;
        var f = Frame;
        Send($"{{\"t\":\"cursor\",\"x\":{screen.X - f.Left},\"y\":{screen.Y - f.Top}{(overWindow ? ",\"w\":1" : "")}}}");
    }

    bool wasOverWindow;
    long lastOverSend;

    public void CursorOff() => Send("{\"t\":\"cursorOff\"}");

    /// A picture of the page (tests and the Settings preview).
    public async Task SnapshotAsync(string path)
    {
        if (web.CoreWebView2 == null) return;
        await using var file = File.Create(path);
        await web.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, file);
    }

    /// Asks the page something (tests): the answer, as a string.
    public async Task<string> AskAsync(string js) =>
        web.CoreWebView2 == null ? "" : await web.CoreWebView2.ExecuteScriptAsync($"String((() => {{ {js} }})())");

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    struct DEVMODE
    {
        [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    static extern bool EnumDisplaySettings(string device, int mode, ref DEVMODE dm);
}
