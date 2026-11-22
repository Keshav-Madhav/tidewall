using System.Reflection;

namespace Tidewall;

/// The scripts every wall page gets: the bridge to this host, then the shared ones in themes/host (the same files the
/// macOS app injects: frame pacing, GPU-context recovery, the morph hook).
internal static class PageScripts
{
    public static string Bridge { get; } = Resource("bridge.js");
    /// The Settings window's frames: the preview's host is the page around it.
    public static string Frame { get; } = Resource("frame.js");
    static readonly string early = Load("early"), late = Load("late");

    public static string Late => late;

    public static string Early(double fps, int maxHz) =>
        $"{early}({{ fps: {fps.ToString(System.Globalization.CultureInfo.InvariantCulture)}, opaque: true, cap: 8, maxHz: {maxHz}, profile: false }});";

    static string Load(string name)
    {
        var path = Path.Combine(Config.ThemesRoot, "host", name + ".js");
        if (File.Exists(path)) return File.ReadAllText(path);
        Log.Write($"JSERR host script missing: {path}");
        return "(() => {})";
    }

    static string Resource(string name)
    {
        using var s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name)!;
        using var r = new StreamReader(s);
        return r.ReadToEnd();
    }
}
