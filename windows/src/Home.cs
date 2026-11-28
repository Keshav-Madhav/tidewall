using System.Globalization;
using System.Reflection;
using System.Text.Json.Nodes;

namespace Tidewall;

/// Where the user is, roughly, as on the Mac: the city of their time zone, from the time-zone table (zone.tab, shipped
/// inside the app: Windows has none of its own), with no location permission. Celestial Atlas draws that city's sky;
/// Wind Map starts on that country.
static class Home
{
    public readonly record struct Place(string Name, double Lat, double Lon, string Tz, string Cc);

    // (lazy: the tables below must exist first; a static initialised in order hit them before they did)
    static readonly Lazy<Place?> zone = new(Find);
    /// Where the sky is drawn from: where Windows' location service says you are (Locator), else your time zone's city.
    /// Windows has no free way to name the town, so the time zone's city's name stays only if it's near (~120 km);
    /// further off, the walls get the coordinates alone. The country (Wind Map's region) is always the time zone's.
    public static Place? Current
    {
        get
        {
            if (Config.Here is not { } h) return zone.Value;
            var z = zone.Value;
            string name = z is { } c && Km(c.Lat, c.Lon, h.Lat, h.Lon) < 120 ? c.Name : "";
            return new Place(name, h.Lat, h.Lon, z?.Tz ?? "", z?.Cc ?? "");
        }
    }
    static double Km(double la1, double lo1, double la2, double lo2)
    {
        double r = Math.PI / 180, dla = (la2 - la1) * r, dlo = (lo2 - lo1) * r;
        double a = Math.Sin(dla / 2) * Math.Sin(dla / 2) + Math.Cos(la1 * r) * Math.Cos(la2 * r) * Math.Sin(dlo / 2) * Math.Sin(dlo / 2);
        return 6371 * 2 * Math.Atan2(Math.Sqrt(a), Math.Sqrt(1 - a));
    }

    /// Windows names time zones its own way ("India Standard Time"); .NET maps them to the standard names, but the
    /// mapping (CLDR) keeps some old spellings that zone.tab has since renamed
    static readonly Dictionary<string, string> Renamed = new()
    {
        ["Asia/Calcutta"] = "Asia/Kolkata", ["Asia/Katmandu"] = "Asia/Kathmandu", ["Asia/Saigon"] = "Asia/Ho_Chi_Minh",
        ["Asia/Rangoon"] = "Asia/Yangon", ["Europe/Kiev"] = "Europe/Kyiv", ["America/Godthab"] = "America/Nuuk",
        ["Atlantic/Faeroe"] = "Atlantic/Faroe", ["America/Buenos_Aires"] = "America/Argentina/Buenos_Aires",
        ["America/Indianapolis"] = "America/Indiana/Indianapolis", ["America/Louisville"] = "America/Kentucky/Louisville",
        ["America/Catamarca"] = "America/Argentina/Catamarca", ["America/Cordoba"] = "America/Argentina/Cordoba",
        ["America/Jujuy"] = "America/Argentina/Jujuy", ["America/Mendoza"] = "America/Argentina/Mendoza",
        ["Pacific/Truk"] = "Pacific/Chuuk", ["Pacific/Ponape"] = "Pacific/Pohnpei", ["Pacific/Enderbury"] = "Pacific/Kanton",
        ["Asia/Ulan_Bator"] = "Asia/Ulaanbaatar", ["Asia/Thimbu"] = "Asia/Thimphu", ["Asia/Dacca"] = "Asia/Dhaka",
        ["Asia/Chongqing"] = "Asia/Shanghai", ["Asia/Harbin"] = "Asia/Shanghai", ["Europe/Uzhgorod"] = "Europe/Kyiv",
        ["Europe/Zaporozhye"] = "Europe/Kyiv", ["America/Montreal"] = "America/Toronto", ["Australia/Canberra"] = "Australia/Sydney",
    };

    static Place? Find()
    {
        try
        {
            string tz = Args.Value("--tz") ?? Iana(TimeZoneInfo.Local) ?? "";
            if (tz.Length == 0) return null;
            if (Renamed.TryGetValue(tz, out var renamed)) tz = renamed;
            foreach (var line in Lines("zone.tab"))
            {
                var f = line.Split('\t');
                if (f.Length < 3 || f[2] != tz) continue;
                if (Coordinates(f[1]) is not { } at) return null;
                var city = tz[(tz.LastIndexOf('/') + 1)..].Replace('_', ' ');
                Log.Write($"site: {TimeZoneInfo.Local.Id} is {tz}");
                return new Place(city, at.Lat, at.Lon, tz, f[0]);
            }
            Log.Write($"site: {tz} isn't in the time-zone table");
        }
        catch (Exception e) { Log.Write("site: " + e.Message); }
        return null;
    }

    /// The standard name of a Windows time zone, from CLDR's table (shipped: the app runs without .NET's globalization
    /// data, so it can't convert them itself). The user's region narrows a shared zone to the right city ("W. Europe
    /// Standard Time" in Italy is Rome); otherwise the zone's main city.
    static string? Iana(TimeZoneInfo zone)
    {
        if (zone.HasIanaId) return zone.Id;
        string? any = null, mine = null, region = UserRegion();
        foreach (var line in Lines("windowsZones.tsv"))
        {
            var f = line.Split('\t');
            if (f.Length < 3 || f[0] != zone.Id) continue;
            if (f[1] == "001") any = f[2];
            if (f[1] == region) mine = f[2];
        }
        return mine ?? any;
    }

    /// Windows' own idea of where the user is (Settings ▸ Time & language ▸ Region: two letters, "US").
    static string? UserRegion()
    {
        try { var sb = new System.Text.StringBuilder(16); return GetUserDefaultGeoName(sb, sb.Capacity) > 1 ? sb.ToString() : null; }
        catch (Exception) { return null; }                                   // (before Windows 10 1709)
    }
    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    static extern int GetUserDefaultGeoName(System.Text.StringBuilder name, int size);

    static IEnumerable<string> Lines(string resource)
    {
        using var s = Assembly.GetExecutingAssembly().GetManifestResourceStream(resource);
        if (s == null) yield break;
        using var r = new StreamReader(s);
        for (string? line; (line = r.ReadLine()) != null;) if (!line.StartsWith('#')) yield return line;
    }

    /// zone.tab's "+2232+08822" or "+404251-0740023": ±DDMM[SS] then ±DDDMM[SS].
    static (double Lat, double Lon)? Coordinates(string iso)
    {
        int split = iso.IndexOfAny(['+', '-'], 1);
        if (split < 0) return null;
        return (Degrees(iso[..split], 2), Degrees(iso[split..], 3));
    }

    static double Degrees(string s, int whole)
    {
        double sign = s[0] == '-' ? -1 : 1;
        var d = s[1..];
        double Part(int at, int len) => d.Length >= at + len ? double.Parse(d.Substring(at, len), CultureInfo.InvariantCulture) : 0;
        return sign * (Part(0, whole) + Part(whole, 2) / 60 + Part(whole + 2, 2) / 3600);
    }

    /// The query the walls and the Settings preview are given (the same as the Mac's).
    public static string Query => Current is { } p
        ? $"&site={Uri.EscapeDataString(p.Name)}&lat={p.Lat.ToString("F3", CultureInfo.InvariantCulture)}&lon={p.Lon.ToString("F3", CultureInfo.InvariantCulture)}" + (p.Tz.Length > 0 ? $"&tz={Uri.EscapeDataString(p.Tz)}" : "")
        : "";

    /// Wind Map's default region: the user's own country, if the map has it (its regions are ISO 3166 three-letter codes).
    static readonly Lazy<string?> region = new(FindRegion);
    public static string? Region => region.Value;

    static string? FindRegion()
    {
        try
        {
            // the country of your time zone's city (as on the Mac), else Windows' region setting; the map's regions are
            // three-letter codes (CLDR's table turns the two-letter ones into those)
            var cc = zone.Value?.Cc ?? UserRegion();
            var iso3 = cc == null ? null : Lines("countries.tsv").Select(l => l.Split('\t')).FirstOrDefault(f => f.Length == 2 && f[0] == cc)?[1];
            if (iso3 == null) { Log.Write($"home region: none for {cc ?? "no region"}"); return null; }
            var manifest = JsonNode.Parse(File.ReadAllText(Path.Combine(Config.ThemesRoot, "variants.json")));
            foreach (var g in manifest?["wind"]?["groups"]?.AsArray() ?? [])
                foreach (var o in g?["options"]?.AsArray() ?? [])
                    if (o?["id"]?.GetValue<string>() is { } id && string.Equals(id, iso3, StringComparison.OrdinalIgnoreCase)) return id;
        }
        catch (Exception e) { Log.Write("home region: " + e.Message); }
        return null;
    }
}
