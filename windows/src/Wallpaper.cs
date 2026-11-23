using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace Tidewall;

/// One display's wall: a borderless window in the desktop layer, behind the icons, showing a theme page in WebView2.
/// The page hears where the windows are (in its device pixels) and says when it's ready.
internal sealed class Wallpaper : Form
{
    public const string Host = "tidewall.local";
    static CoreWebView2Environment? environment;
    public static CoreWebView2Environment? SharedEnvironment => environment;

    /// One browser for every wall and the Settings window (its data in %LOCALAPPDATA%\TidewallData\WebView2).
    public static async Task<CoreWebView2Environment> EnvironmentAsync() => environment ??= await CoreWebView2Environment.CreateAsync(null,
        Path.Combine(Config.DataDir, "WebView2"), new CoreWebView2EnvironmentOptions("--autoplay-policy=no-user-gesture-required --disable-features=msSmartScreenProtection" +
            (Args.Value("--cdp") is { } port ? $" --remote-debugging-port={int.Parse(port)}" : "")));   // tests: drive the pages from outside

    readonly WebView2 web = new() { Dock = DockStyle.Fill, DefaultBackgroundColor = Paper };
    readonly string theme;
    /// The display this wall is drawn on.
    public Display Screen { get; }
    public Rectangle Frame => Screen.Bounds;
    public bool Ready { get; private set; }
    public bool Paused { get; private set; }
    public bool WantsCursor { get; private set; } = true;
    public string Theme => theme;
    /// The variant the page was opened with (a change of it, or of its default, starts this wall again).
    public string? LoadedVariant { get; private set; }
    public event Action<Wallpaper>? BecameReady;

    string lastWindows = "", lastIcons = "", lastDesk = "";
    DateTime started = DateTime.UtcNow;

    public Wallpaper(Display screen, string theme)
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

    /// The wall this one replaces: this one starts beneath it, and it's closed once this one is ready.
    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public Wallpaper? Replacing { get; set; }

    bool fadeIn;
    string? hideScript;
    readonly List<DateTime> crashes = [];
    static readonly Color Paper = Color.FromArgb(239, 228, 204);

    public async Task StartAsync(DesktopLayer.Host layer)
    {
        var t0 = DateTime.UtcNow;
        // the first wall on a display (not one replacing another): until its page is ready, what was there before (your
        // own wallpaper) rather than a blank colour, and then the wall fades in over it, as on the Mac
        fadeIn = Replacing is not { IsDisposed: false } && !Args.Has("--test");
        if (fadeIn) ShowDesktopPicture();
        Show();
        DesktopLayer.Attach(Handle, layer, Screen.Bounds, Replacing is { IsDisposed: false } r ? r.Handle : default);
        started = t0;

        await web.EnsureCoreWebView2Async(await EnvironmentAsync());
        var core = web.CoreWebView2;
        // (the page's root doesn't exist yet when this runs: it's hidden as soon as it does; and only on this first load,
        // so a reload later, a lost GPU context say, never starts hidden)
        if (fadeIn) hideScript = await core.AddScriptToExecuteOnDocumentCreatedAsync(
            "(()=>{const h=()=>{const e=document.documentElement;if(e){e.style.opacity='0';return true}};if(!h())new MutationObserver((_,o)=>{if(h())o.disconnect()}).observe(document,{childList:true})})()");
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
        core.ProcessFailed += (_, e) =>
        {
            // as on the Mac: failing over and over (three times in a minute), give the system 10 s before trying again
            var now = DateTime.UtcNow;
            crashes.RemoveAll(t => (now - t).TotalSeconds > 60); crashes.Add(now);
            int wait = crashes.Count > 2 ? 10000 : 0;
            Log.Write($"[{theme}] web process failed ({e.ProcessFailedKind}); reloading{(wait > 0 ? " in 10 s" : "")}");
            Ready = false;
            _ = Task.Delay(wait).ContinueWith(_ => BeginInvoke(() => { if (!IsDisposed && web.CoreWebView2 != null) web.CoreWebView2.Reload(); }));
        };

        LoadedVariant = Config.Variant(theme);
        var variant = LoadedVariant is { } v ? "&v=" + Uri.EscapeDataString(v) : "";
        core.Navigate($"https://{Host}/{Config.Page(theme)}.html?wallpaper=1{variant}{Home.Query}");   // (the place: Celestial Atlas draws its sky)
    }

    public int RefreshRate()
    {
        // the display's refresh rate, for the page's frame pacer (it draws at most this fast while things move)
        var mode = new DEVMODE { dmSize = (short)System.Runtime.InteropServices.Marshal.SizeOf<DEVMODE>() };
        return EnumDisplaySettings(Screen.Device, -1, ref mode) && mode.dmDisplayFrequency > 1 ? mode.dmDisplayFrequency : 60;
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
                lastWindows = lastIcons = lastDesk = lastDeskIcons = "";
                SendDesk();
                Send($"{{\"t\":\"me\",\"seed\":{Config.Seed}}}");
                if (Pace != 1) Send($"{{\"t\":\"pace\",\"k\":{Pace}}}");
                Paused = false; LaidOut = false;                           // (it's told to rest after its first layout: Dispatch)
                if (fadeIn) { fadeIn = false; FadeIn(); }
                else Unhide();                                             // (never left hidden, whatever order a busy start took)
                Log.Write($"[{theme}] ready on {Screen.Name} {Screen.Bounds} scale {PixelScale:0.##} in {(DateTime.UtcNow - started).TotalSeconds:0.0} s");
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
        if (!Ready || IsDisposed || web.IsDisposed || web.CoreWebView2 == null) return;   // (a wall already closed: nothing to tell)
        var literal = JsonSerializer.Serialize(json);
        _ = web.CoreWebView2.ExecuteScriptAsync($"window.__live={(live ? "true" : "false")};window.__hostSend({literal});window.__live=false;");
    }

    /// This display's scale (its device pixels per page pixel).
    public double PixelScale => DeviceDpi / 96.0;

    /// Where this display sits among the others, in page pixels.
    /// This wall alone: a world of one.
    WorldPart Alone => new(Screen, PixelScale, new RectangleF(0, 0, (float)(Screen.Bounds.Width / PixelScale), (float)(Screen.Bounds.Height / PixelScale)));

    /// Where this display sits in its world, all in points (the page's own pixels), as the Mac says it.
    public void SendDesk(IReadOnlyList<WorldPart>? world = null)
    {
        world ??= [Alone];
        var frames = world.Select(p => p.Points).ToList();
        var u = frames.Aggregate(frames[0], RectangleF.Union);
        static int Px(double v) => (int)Math.Round(v);
        var fr = string.Join(",", frames.Select(f => $"[{Px(f.X - u.X)},{Px(f.Y - u.Y)},{Px(f.Width)},{Px(f.Height)}]"));
        int i = world.ToList().FindIndex(p => p.Screen.Name == Screen.Name);
        var me = i >= 0 ? frames[i] : frames[0];
        var main = world.FirstOrDefault(p => p.Screen.Primary)?.Points ?? me;
        var msg = $"{{\"t\":\"desk\",\"fr\":[{fr}],\"x\":{Px(me.X - u.X)},\"y\":{Px(me.Y - u.Y)},\"w\":{Px(me.Width)},\"h\":{Px(me.Height)}," +
                  $"\"uw\":{Px(u.Width)},\"uh\":{Px(u.Height)},\"i\":{Math.Max(0, i)},\"n\":{frames.Count}," +
                  $"\"mx\":{Px(main.X + main.Width / 2.0 - u.X)},\"my\":{Px(main.Y + main.Height / 2.0 - u.Y)},\"mw\":{Px(main.Width)},\"mh\":{Px(main.Height)}}}";
        if (msg == lastDesk) return;
        lastDesk = msg;
        lastDeskIcons = "";                                                // (pages place icons by their world offset, which may have moved)
        Send(msg);
    }

    /// The windows over this display (screen pixels in), as the page wants them: its own device pixels.
    /// It has been told the windows at least once since its page came up.
    public bool LaidOut { get; private set; }

    public void SendWindows(IReadOnlyList<TrackedWindow> windows, bool live)
    {
        LaidOut = true;
        var f = Frame;
        var mine = windows.Where(w => w.Bounds.IntersectsWith(f)).ToList();
        string Box(Rectangle r) => $"[{r.Left - f.Left},{r.Top - f.Top},{r.Right - f.Left},{r.Bottom - f.Top}]";
        var names = JsonSerializer.Serialize(mine.Select(w => w.Name).ToArray());
        var wins = $"{{\"t\":\"windows\",\"live\":{(live ? "true" : "false")},\"r\":[{string.Join(",", mine.Select(w => Box(w.Bounds)))}],\"n\":{names},\"sm\":[{string.Join(",", mine.Select(_ => "0"))}]}}";
        if (wins != lastWindows) { lastWindows = wins; Send(wins, live); }
        int m = (int)Math.Round(Config.Margin * PixelScale);   // the room the scene keeps around each window, in page pixels
        var icons = $"{{\"t\":\"icons\",\"vis\":true,\"r\":[{string.Join(",", mine.Select(w => Box(Rectangle.Inflate(w.Bounds, m, m))))}]}}";
        if (icons != lastIcons) { lastIcons = icons; Send(icons, live); }
    }

    /// The desktop icons in this wall's world (screen pixels in), as the page wants them: its own device pixels.
    /// The desktop's icons across its world, in this display's own device pixels (an icon on a display with another
    /// scale goes through the world's points to get here).
    public void SendDeskIcons(DeskIcons di, IReadOnlyList<WorldPart>? world = null)
    {
        world ??= [Alone];
        var mine = world.FirstOrDefault(p => p.Screen.Name == Screen.Name) ?? Alone;
        double k = PixelScale;
        string Local(Rectangle r, WorldPart on)
        {
            if (on.Screen.Name == Screen.Name) return $"[{r.Left - Frame.Left},{r.Top - Frame.Top},{r.Right - Frame.Left},{r.Bottom - Frame.Top}]";
            PointF a = on.ToPoints(new Point(r.Left, r.Top)), b = on.ToPoints(new Point(r.Right, r.Bottom));
            int X(float v) => (int)Math.Round((v - mine.Points.X) * k);
            int Y(float v) => (int)Math.Round((v - mine.Points.Y) * k);
            return $"[{X(a.X)},{Y(a.Y)},{X(b.X)},{Y(b.Y)}]";
        }
        string Enc(IEnumerable<Rectangle> rs) => string.Join(",", rs.Select(r => (r, on: world.FirstOrDefault(p => p.Screen.Bounds.IntersectsWith(r))))
            .Where(x => x.on != null).Select(x => Local(x.r, x.on!)));
        var msg = $"{{\"t\":\"dicons\",\"r\":[{Enc(di.Icons)}],\"c\":[{Enc(di.Clusters)}],\"i\":[{Enc(di.Images)}]}}";
        if (msg == lastDeskIcons) return;
        lastDeskIcons = msg;
        Send(msg);
    }
    string lastDeskIcons = "";

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
    /// On battery with Settings ▸ On battery ▸ Calmer: every wall draws at half its rate (2), else 1.
    public static double Pace { get; private set; } = 1;
    public static void SetPace(double k, IEnumerable<Wallpaper> walls)
    {
        if (k == Pace) return;
        Pace = k;
        foreach (var w in walls) w.Send($"{{\"t\":\"pace\",\"k\":{k}}}");
    }

    /// A still picture of the wall: the page let go (all of its memory with it) while nobody would see it move (away
    /// from the PC a while, or behind a maximised window). Made again when it's wanted.
    public bool Frozen { get; private set; }
    void ShowDesktopPicture()
    {
        try
        {
            var path = new System.Text.StringBuilder(520);
            if (Native.SystemParametersInfo(0x73, path.Capacity, path, 0) && File.Exists(path.ToString()))   // SPI_GETDESKWALLPAPER
            {
                using var f = File.OpenRead(path.ToString());
                BackgroundImage = Image.FromStream(new MemoryStream(ReadAll(f)));
                BackgroundImageLayout = ImageLayout.Zoom;
            }
            BackColor = ColorTranslator.FromWin32(Native.GetSysColor(1));                 // COLOR_DESKTOP: a plain-colour desktop, and round the picture
            web.DefaultBackgroundColor = Color.Transparent;
        }
        catch (Exception e) { Log.Write($"[{theme}] no desktop picture to fade from ({e.Message})"); }
        static byte[] ReadAll(Stream s) { using var m = new MemoryStream(); s.CopyTo(m); return m.ToArray(); }
    }

    void FadeIn()
    {
        if (hideScript != null) { web.CoreWebView2?.RemoveScriptToExecuteOnDocumentCreated(hideScript); hideScript = null; }
        _ = web.CoreWebView2?.ExecuteScriptAsync("{const e=document.documentElement;e.animate([{opacity:0},{opacity:1}],{duration:700,easing:'ease-out'}).onfinish=()=>{e.style.opacity=''};e.style.opacity='1'}");
        // once it shows, the picture beneath it isn't needed; and whatever happened meanwhile, it's shown
        _ = Task.Delay(1500).ContinueWith(_ => BeginInvoke(() => { if (IsDisposed || Frozen) return; Unhide(); var b = BackgroundImage; BackgroundImage = null; b?.Dispose(); web.DefaultBackgroundColor = BackColor = Paper; }));
    }

    void Unhide()
    {
        if (hideScript != null) { web.CoreWebView2?.RemoveScriptToExecuteOnDocumentCreated(hideScript); hideScript = null; }
        _ = web.CoreWebView2?.ExecuteScriptAsync("{const e=document.documentElement;if(e&&e.style.opacity==='0'&&!e.getAnimations().length)e.style.opacity=''}");
    }

    public async Task FreezeAsync()
    {
        if (Frozen || web.CoreWebView2 == null) return;
        Frozen = true;
        try
        {
            using var png = new MemoryStream();
            await web.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, png);
            BackgroundImage = Image.FromStream(new MemoryStream(png.ToArray()));
            BackgroundImageLayout = ImageLayout.Stretch;
        }
        catch (Exception e)
        {
            // no picture of your own desktop to stand in: the page stays (paused) rather than something that isn't
            // yours (the theme's thumbnail has demo windows on it) or a blank
            Log.Write($"[{theme}] no still picture ({e.Message}): the page stays, paused");
            Frozen = false;
            return;
        }
        Ready = false;
        Controls.Remove(web);
        web.Dispose();
        Log.Write($"[{theme}] let go on {Screen.Name}: a still picture stands in");
    }

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
