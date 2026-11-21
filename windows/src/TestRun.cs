using System.Drawing.Imaging;

namespace Tidewall;

/// --test DIR [--secs S]: a hands-off run for CI and the VM. Opens two plain windows, photographs the whole desktop and
/// each wall, glides one window across the screen, photographs again, logs what every wall reports, and quits.
internal static class TestRun
{
    static readonly string dir = Path.GetFullPath(Args.Value("--test") ?? "test-out");

    public static void Start(TidewallApp app)
    {
        Directory.CreateDirectory(dir);
        _ = Run(app);
    }

    static async Task Run(TidewallApp app)
    {
        try
        {
            if (Args.Has("--clear-desk")) ClearDesk(app);
            await Task.Delay(1500);
            var work = Screen.PrimaryScreen!.WorkingArea;
            var a = Open(app, "Tidewall test · Notes", Rect(work, 0.18, 0.18, 0.40, 0.42), Color.FromArgb(250, 250, 252));
            var b = Open(app, "Tidewall test · Code", Rect(work, 0.62, 0.52, 0.28, 0.32), Color.FromArgb(36, 37, 41));
            // a fresh machine starts WebView2 slowly the first time: the settle counts from when every wall is up
            var started = DateTime.UtcNow;
            while (app.Walls.Any(w => !w.Ready) && DateTime.UtcNow - started < TimeSpan.FromSeconds(90)) await Task.Delay(250);
            Log.Write($"test: walls ready after {(DateTime.UtcNow - started).TotalSeconds:0.0} s ({app.Walls.Count(w => w.Ready)}/{app.Walls.Count})");
            await Task.Delay(TimeSpan.FromSeconds(double.Parse(Args.Value("--settle") ?? "9")));
            await Probe(app, "a");
            await Shoot(app, "a");
            foreach (var w in app.Walls) await w.AskAsync(FrameProbe);
            Log.Write($"bench: hop starts {DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}");

            // the first window glides 30% of the screen right and 12% down in 0.6 s, as a drag would
            var from = a.Location;
            var to = new Point(from.X + (int)(work.Width * 0.30), from.Y + (int)(work.Height * 0.12));
            for (int i = 1; i <= 36; i++)
            {
                double t = i / 36.0, e = t * t * (3 - 2 * t);
                a.Location = new Point((int)(from.X + (to.X - from.X) * e), (int)(from.Y + (to.Y - from.Y) * e));
                await Task.Delay(16);
            }
            Log.Write("test: glide done");
            await Task.Delay(4000);
            for (int i = 0; i < app.Walls.Count; i++) { var json = await app.Walls[i].AskAsync(FrameProbe); Log.Write($"eval [{i}] " + (string.IsNullOrEmpty(json) ? "(no answer)" : System.Text.Json.JsonSerializer.Deserialize<string>(json))); }
            await Probe(app, "b");
            await Shoot(app, "b");
            Log.Write("TEST DONE");
        }
        catch (Exception e) { Log.Write($"CRASH test: {e}"); }
        Application.Exit();
    }

    /// Every frame the page's loop is given, and apart the ones while it said it was settling (tools/smooth-check.py's
    /// probe): the first call hooks requestAnimationFrame, later ones return what it saw.
    const string FrameProbe = "if (!window.__ft) { window.__ft = []; window.__fs = []; let last = 0; const r0 = window.requestAnimationFrame; " +
        "window.requestAnimationFrame = cb => r0(t => { const n = Date.now(); if (n - last > 4) { window.__ft.push(n); " +
        "if (window.__twSettling && window.__twSettling()) window.__fs.push(n); } last = n; cb(t); }); return 'hooked'; } " +
        "return JSON.stringify({ f: window.__ft, s: window.__fs });";

    /// CI: the runner's own windows out of the way, so the pictures show the test windows on the wall.
    static void ClearDesk(TidewallApp app)
    {
        app.Tracker.Look();
        foreach (var t in app.Tracker.Windows) Native.ShowWindow(t.Handle, Native.SW_MINIMIZE);
        app.Tracker.Look();
    }

    static Rectangle Rect(Rectangle r, double x, double y, double w, double h) =>
        new((int)(r.X + r.Width * x), (int)(r.Y + r.Height * y), (int)(r.Width * w), (int)(r.Height * h));

    static Form Open(TidewallApp app, string title, Rectangle bounds, Color fill)
    {
        var f = new Form { Text = title, StartPosition = FormStartPosition.Manual, Bounds = bounds, BackColor = fill, ShowInTaskbar = true, TopMost = true };
        f.Show();
        app.Tracker.OwnWindows.Add(f.Handle);
        app.Tracker.Look();
        return f;
    }

    static async Task Probe(TidewallApp app, string tag)
    {
        for (int i = 0; i < app.Walls.Count; i++)
        {
            var w = app.Walls[i];
            var answer = await w.AskAsync(
                "return JSON.stringify({ dpr: devicePixelRatio, w: innerWidth, h: innerHeight, " +
                "fb: typeof FB !== 'undefined' && !!FB, icons: typeof icons !== 'undefined' ? icons.length : -1, " +
                "paused: typeof paused !== 'undefined' ? paused : null, settling: !!(window.__twSettling && window.__twSettling()), " +
                "stage: typeof ready !== 'undefined' ? ready : null, buildGen: typeof buildGen !== 'undefined' ? buildGen : null, " +
                "gpu: (() => { try { const g = document.createElement('canvas').getContext('webgl2'), x = g.getExtension('WEBGL_debug_renderer_info'); " +
                "return x ? g.getParameter(x.UNMASKED_RENDERER_WEBGL) : g.getParameter(g.RENDERER); } catch (e) { return 'none'; } })() })");
            Log.Write($"probe {tag} wall {i} {w.Theme} on {w.Screen.DeviceName} ready={w.Ready} paused={w.Paused} {answer}");
        }
        Log.Write($"probe {tag} windows: {string.Join(" | ", app.Tracker.Windows.Select(t => $"{t.Owner} {t.Bounds}"))}");
    }

    static async Task Shoot(TidewallApp app, string tag)
    {
        var all = SystemInformation.VirtualScreen;
        using (var bmp = new Bitmap(all.Width, all.Height))
        {
            using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(all.Location, Point.Empty, all.Size);
            bmp.Save(Path.Combine(dir, $"desk-{tag}.png"), ImageFormat.Png);
        }
        for (int i = 0; i < app.Walls.Count; i++) await app.Walls[i].SnapshotAsync(Path.Combine(dir, $"wall{i}-{tag}.png"));
        Log.Write($"test: shot {tag}");
    }
}
