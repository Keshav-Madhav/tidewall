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

    public static void Init()
    {
        path = Args.Value("--log") ?? Path.Combine(Config.DataDir, "Tidewall.log");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
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
        ("garden", "Garden Plan · very low"), ("railway", "Model Railway · very low"), ("meadow", "Meadow · high"),
        ("beach", "Beach · medium"),
    ];

    /// Walls that can draw one world across several displays.
    public static readonly HashSet<string> SpanThemes =
        ["celestial", "snow", "wind", "railway", "reef", "inkmap", "garden", "gallery", "beach", "meadow", "estate"];

    public const string DefaultTheme = "inkmap";

    public static string DataDir { get; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Tidewall");
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
    public static double IdleMinutes { get => Get("idleMinutes", 3.0); set => Set("idleMinutes", value); }
    public static int Battery { get => Get("battery", 0); set => Set("battery", value); }
    public static string? Variant(string theme) => data["variant." + theme]?.GetValue<string>();
}
