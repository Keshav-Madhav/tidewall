using Windows.Devices.Geolocation;

namespace Tidewall;

/// Where you are, from Windows' location service, so the walls that draw the real sky (Courtyard's sun and shadows,
/// Celestial Atlas's stars) draw it over you, as on the Mac. A time zone alone put all of India at Kolkata and all of
/// China at Shanghai: an hour or more off at sunset. Windows asks you once; until it's allowed (or if it isn't), the
/// city of your time zone stands in.
///
/// Kept rounded to a tenth of a degree (about 10 km) in Tidewall's own settings and used only on this PC. Looked again
/// every six hours (and on waking, if it's been that long); the walls are redrawn only when you've moved ~25 km.
internal sealed class Locator : IDisposable
{
    readonly Action onMove;
    readonly System.Windows.Forms.Timer timer = new() { Interval = 6 * 3600 * 1000 };
    bool looking;

    public Locator(Action onMove)
    {
        this.onMove = onMove;
        timer.Tick += (_, _) => Look(force: true);
        if (Args.Has("--test") || Args.Value("--tz") != null) return;   // (test runs keep to the time zone they're given)
        timer.Start();
        Look();
    }

    /// One fix, if Windows lets us and the last one is old (or we're told to look).
    public async void Look(bool force = false)
    {
        if (looking || !timer.Enabled) return;
        if (!force && Config.Here is { } h && DateTime.UtcNow - h.At < TimeSpan.FromHours(6)) return;
        looking = true;
        try
        {
            Log.Write("location: asking Windows");
            var access = await Geolocator.RequestAccessAsync();
            if (access != GeolocationAccessStatus.Allowed) { Log.Write($"location: {access}"); return; }
            var pos = await new Geolocator { DesiredAccuracy = PositionAccuracy.Default }.GetGeopositionAsync(TimeSpan.FromHours(1), TimeSpan.FromSeconds(30));
            var p = pos.Coordinate.Point.Position;
            double lat = Math.Round(p.Latitude, 1), lon = Math.Round(p.Longitude, 1);
            var was = Config.Here;
            Config.Here = (lat, lon, DateTime.UtcNow);
            if (was is { } w && Math.Abs(w.Lat - lat) <= .25 && Math.Abs(w.Lon - lon) <= .25) return;
            Log.Write("location: moved (the sky is redrawn)");
            onMove();
        }
        catch (Exception e) { Log.Write($"location: no fix ({e.GetType().Name})"); }
        finally { looking = false; }
    }

    public void Dispose() => timer.Dispose();
}
