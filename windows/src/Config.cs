using System.Text.Json;
using System.Text.Json.Nodes;

namespace Tidewall;

/// Launch arguments (for testing and development).
internal static class Args
{
    static string[] all = [];
    public static void Init(string[] args) => all = args;
    public static bool Has(string flag) => all.Contains(flag);
    public static string? Value(string flag)
    {
        int i = Array.IndexOf(all, flag);
        return i >= 0 && i + 1 < all.Length ? all[i + 1] : null;
    }
}

internal static class Log
{
    static readonly object gate = new();
    static string? path;
    public static string Path => path ?? "";

    public static void Init()
    {
        path = Args.Value("--log") ?? System.IO.Path.Combine(Config.DataDir, "Tidewall.log");
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        try { if (File.Exists(path) && new FileInfo(path).Length > 5_000_000) File.Delete(path); } catch (IOException) { }
    }

    public static void Write(string line)
    {
        if (path == null) return;
        lock (gate)
        {
            try { File.AppendAllText(path, $"{DateTime.Now:HH:mm:ss.fff} {line}{Environment.NewLine}"); } catch (IOException) { }
        }
    }
}

/// Settings, kept as JSON in %APPDATA%\Tidewall (the same names the Settings page and the macOS app use).
internal static class Config
{
    public static readonly (string Id, string Label)[] Themes =
    [
        ("inkmap", "Ink Map · very low"), ("estate", "Marauders · very low"), ("gallery", "Gallery · none"),
        ("wind", "Wind Map · medium"), ("lava", "Lava Lamp · low"), ("tunnel", "Wind Tunnel · high"),
        ("reef", "Koi Reef · medium"), ("snow", "Snowfall · low"), ("celestial", "Celestial Atlas · none"),
        ("courtyard", "Courtyard · low"),
        ("garden", "Garden Plan · very low"), ("railway", "Model Railway · very low"), ("meadow", "Meadow · high"),
        ("beach", "Beach · medium"),
    ];

    /// Walls that can draw one world across several displays.
    public static readonly HashSet<string> SpanThemes =
        ["celestial", "snow", "wind", "railway", "reef", "inkmap", "garden", "gallery", "beach", "meadow", "estate"];

    public const string DefaultTheme = "inkmap";

    /// The log and the browser's cache. Not %LOCALAPPDATA%\Tidewall: that's where the installer puts the app itself (a
    /// folder there already reads as "installed", and uninstalling clears it).
    public static string DataDir { get; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TidewallData");
    static string SettingsPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Tidewall", "settings.json");

    public static string ThemesRoot { get; } = Path.GetFullPath(Args.Value("--themes") ?? Path.Combine(AppContext.BaseDirectory, "themes"));

    public static string Version { get; } =
        typeof(Config).Assembly.GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "0.0.0";

    static JsonObject data = [];

    public static void Load()
    {
        try { if (File.Exists(SettingsPath)) data = JsonNode.Parse(File.ReadAllText(SettingsPath)) as JsonObject ?? []; }
        catch (JsonException) { data = []; }
    }

    static void Save()
    {
        if (Args.Has("--test")) return;   // test runs never touch your settings
        Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath)!);
        File.WriteAllText(SettingsPath, data.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
    }

    static T Get<T>(string key, T fallback)
    {
        try { return data[key] is { } n ? n.GetValue<T>() : fallback; } catch (InvalidOperationException) { return fallback; }
    }

    static void Set<T>(string key, T value) { data[key] = JsonValue.Create(value); Save(); }

    public static string? ThemeOverride { get; set; } = Args.Value("--theme");

    public static string Theme
    {
        get => ThemeOverride ?? Get("theme", DefaultTheme);
        set { ThemeOverride = null; Set("theme", value); }
    }

    public static string Label(string id) => Themes.FirstOrDefault(t => t.Id == id).Label?.Split(" · ")[0] ?? id;

    /// The page each wall is drawn by (the Beach wall's page is flat.html).
    public static string Page(string id) => id == "beach" ? "flat" : id;

    public static double Fps { get => Get("fps", 0.0); set => Set("fps", value); }
    /// Settings ▸ Optimize for: 0 Performance, 1 Balanced (the default), 2 Quality (see themes/host/early.js).
    public static int Tier { get => Math.Clamp(Get("tier", 1), 0, 2); set => Set("tier", value); }
    public static double TierRes => Tier == 0 ? 0.75 : 1;
    public static double Margin { get => Math.Clamp(Get("margin", 140.0), 0, 400); set => Set("margin", value); }
    /// Seeds the generated names (your walker, the strangers): chosen once, stable across launches.
    public static int Seed
    {
        get
        {
            if (data["seed"] is { } n) return n.GetValue<int>();
            int v = Random.Shared.Next(1, int.MaxValue);
            Set("seed", v);
            return v;
        }
    }
    public static bool Paused { get => Get("paused", false); set => Set("paused", value); }
    /// Rest after this long with no keyboard or mouse (0: never). Test runs never rest: a CI machine has no input at all.
    public static double IdleMinutes { get => Args.Has("--test") ? 0 : Get("idleMinutes", 3.0); set { Set("idleMinutes", value); if (value > 0) IdleLast = value; } }
    public static int Battery { get => Get("battery", 0); set => Set("battery", value); }
    /// A theme's own sub-choice (Wind Map's region, …): the saved one, else the Mac's defaults: Wind Map on your own
    /// country, Wind Tunnel (no model chosen) over your desktop icons when you have some
    public static string? Variant(string theme) => data["variant." + theme]?.GetValue<string>()
        ?? (theme == "wind" ? Home.Region : theme == "tunnel" && IconsPresent ? "none" : null);
    /// Whether the desktop has icons (the last read; before this launch's first, the last launch's).
    public static bool IconsPresent { get => Get("iconsPresent", false); set { if (value != IconsPresent) Set("iconsPresent", value); } }
    public static void SetVariant(string theme, string id) => Set("variant." + theme, id);

    /// A display's own wall, if it has one (else it shows the main wall). Keyed by the display's device name.
    public static string? OwnTheme(string device) => ThemeOverride == null ? data["theme.display." + device]?.GetValue<string>() : null;
    public static string ThemeFor(Display s) => OwnTheme(s.Name) ?? Theme;
    public static void SetOwnTheme(string device, string? theme)
    {
        if (theme == null) data.Remove("theme.display." + device); else data["theme.display." + device] = theme;
        Save();
    }
    public static void ClearDisplayThemes()
    {
        foreach (var k in data.Select(kv => kv.Key).Where(k => k.StartsWith("theme.display.")).ToList()) data.Remove(k);
        Save();
    }
    public static bool IsTheme(string? id) => Themes.Any(t => t.Id == id);

    /// Each wall keeps your desktop icons clear (on by default: unlike Finder's, Explorer's need no permission).
    public static bool DeskIcons { get => Get("deskIcons", true); set => Set("deskIcons", value); }
    /// The window has been shown once (the first launch ever shows it, even at login).
    /// Where the Settings window was last left.
    public static Rectangle? WindowBounds
    {
        get { try { var p = data["windowBounds"]?.GetValue<string>()?.Split(',').Select(int.Parse).ToArray(); return p is { Length: 4 } ? new Rectangle(p[0], p[1], p[2], p[3]) : null; } catch (FormatException) { return null; } }
        set { if (value is { } r) Set("windowBounds", $"{r.X},{r.Y},{r.Width},{r.Height}"); }
    }
    public static bool Welcomed { get => Get("welcomed", false); set => Set("welcomed", value); }
    public static bool AutoUpdate { get => Get("autoUpdate", true); set => Set("autoUpdate", value); }
    public static bool SpanWorlds { get => Get("spanWorlds", true); set => Set("spanWorlds", value); }
    public static bool ReactWindows { get => Get("reactWindows", true); set => Set("reactWindows", value); }
    public static bool ReactCursor { get => Get("reactCursor", true); set => Set("reactCursor", value); }
    /// The idle time last chosen, so turning "rest when idle" back on restores it.
    public static double IdleLast { get => Get("idleLast", 3.0); set => Set("idleLast", value); }
    public static string? NotesSeen { get => data["notesSeen"]?.GetValue<string>(); set => Set("notesSeen", value); }
    /// What's New has something to say: this version is newer than the newest one whose notes you've seen (as on the Mac).
    public static bool HasNewNotes => Changelog.Length > 0 && (NotesSeen is not { } seen
        || !System.Version.TryParse(seen, out var s) || !System.Version.TryParse(Version, out var v) || v > s);
    public static string Changelog
    {
        get { try { return File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "CHANGELOG.md")); } catch (IOException) { return ""; } }
    }
}
