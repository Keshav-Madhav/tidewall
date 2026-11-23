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

    public static Place? Current { get; } = Find();

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
            using var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("zone.tab");
            if (s == null) return null;
            using var r = new StreamReader(s);
            for (string? line; (line = r.ReadLine()) != null;)
            {
                if (line.StartsWith('#')) continue;
                var f = line.Split('\t');
                if (f.Length < 3 || f[2] != tz) continue;
                if (Coordinates(f[1]) is not { } at) return null;
                var city = tz[(tz.LastIndexOf('/') + 1)..].Replace('_', ' ');
                return new Place(city, at.Lat, at.Lon, tz, f[0]);
            }
            Log.Write($"site: {tz} isn't in the time-zone table");
        }
        catch (Exception e) { Log.Write("site: " + e.Message); }
        return null;
    }

    static string? Iana(TimeZoneInfo zone)
    {
        if (zone.HasIanaId) return zone.Id;
        // the region narrows a shared Windows zone to the right city ("W. Europe Standard Time" in Italy is Rome)
        string region = "001";
        try { region = RegionInfo.CurrentRegion.TwoLetterISORegionName; } catch (ArgumentException) { }
        return TimeZoneInfo.TryConvertWindowsIdToIanaId(zone.Id, region, out var id) ? id
             : TimeZoneInfo.TryConvertWindowsIdToIanaId(zone.Id, out id) ? id : null;
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
        ? $"&site={Uri.EscapeDataString(p.Name)}&lat={p.Lat.ToString("F3", CultureInfo.InvariantCulture)}&lon={p.Lon.ToString("F3", CultureInfo.InvariantCulture)}&tz={Uri.EscapeDataString(p.Tz)}"
        : "";

    /// Wind Map's default region: the user's own country, if the map has it (its regions are ISO 3166 three-letter codes).
    public static string? Region { get; } = FindRegion();

    static string? FindRegion()
    {
        try
        {
            string? iso3 = null;
            if (Current is { } p) try { iso3 = new RegionInfo(p.Cc).ThreeLetterISORegionName; } catch (ArgumentException) { }
            iso3 ??= RegionInfo.CurrentRegion.ThreeLetterISORegionName;
            var manifest = JsonNode.Parse(File.ReadAllText(Path.Combine(Config.ThemesRoot, "variants.json")));
            foreach (var g in manifest?["wind"]?["groups"]?.AsArray() ?? [])
                foreach (var o in g?["options"]?.AsArray() ?? [])
                    if (o?["id"]?.GetValue<string>() is { } id && string.Equals(id, iso3, StringComparison.OrdinalIgnoreCase)) return id;
        }
        catch (Exception e) { Log.Write("home region: " + e.Message); }
        return null;
    }
}
