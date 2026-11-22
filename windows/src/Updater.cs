using Velopack;
using Velopack.Sources;

namespace Tidewall;

/// Updates, from the GitHub releases (Velopack: the installer's own update channel for this machine's processor).
/// Checked at launch and every 6 hours; a new version downloads in the background and installs while the screen is
/// locked (or straight away from Settings), then Tidewall starts again. Off in Settings: nothing is checked.
internal sealed class Updater
{
    const string Repo = "https://github.com/Keshav-Madhav/tidewall";
    readonly UpdateManager? manager;
    readonly System.Windows.Forms.Timer timer = new() { Interval = 6 * 3600 * 1000 };
    UpdateInfo? found;
    UpdateInfo? ready;

    /// idle, checking, downloading, ready, current, failed, off — the Settings page's words.
    public string State { get; private set; } = "idle";
    public string? Version => (ready ?? found)?.TargetFullRelease.Version.ToString();
    public string? Error { get; private set; }
    public long Checked { get; private set; }
    public event Action? Changed;

    public Updater()
    {
        try
        {
            // tests: TIDEWALL_UPDATE_SOURCE=<folder> takes updates from a local folder of packages instead of GitHub
            IUpdateSource source = Environment.GetEnvironmentVariable("TIDEWALL_UPDATE_SOURCE") is { Length: > 0 } local
                ? new SimpleFileSource(new DirectoryInfo(local)) : new GithubSource(Repo, null, false);
            manager = new UpdateManager(source);
            if (!manager.IsInstalled) manager = null;   // a development build, run from a folder: nothing to update
        }
        catch (Exception e) { Log.Write($"updates: {e.Message}"); manager = null; }
        if (manager == null) { State = "off"; Error = "This copy wasn't installed with the installer, so it doesn't update itself."; return; }
        timer.Tick += (_, _) => _ = Check();
        timer.Start();
        if (Config.AutoUpdate) _ = Check();
    }

    public async Task Check(bool manual = false)
    {
        if (manager == null || State is "checking" or "downloading" or "ready") return;
        if (!Config.AutoUpdate && !manual) return;
        Set("checking");
        try
        {
            found = await manager.CheckForUpdatesAsync();
            Checked = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            if (found == null) { Set("current"); return; }
            Log.Write($"update: {found.TargetFullRelease.Version} found");
            Set("downloading");
            await manager.DownloadUpdatesAsync(found);
            ready = found;
            Log.Write($"update: {ready.TargetFullRelease.Version} ready");
            Set("ready");
            if (Environment.GetEnvironmentVariable("TIDEWALL_UPDATE_INSTALL_NOW") == "1") Install();   // tests: no waiting for a lock
        }
        catch (Exception e) { Error = e.Message; Log.Write($"update failed: {e.Message}"); Set("failed"); }
    }

    /// Install the downloaded version now and start it again (in the background, as at login).
    public void Install()
    {
        if (manager == null || ready == null) return;
        Log.Write($"update: installing {ready.TargetFullRelease.Version}");
        manager.ApplyUpdatesAndRestart(ready, ["--background"]);
    }

    /// The screen just locked: a good moment, nobody is looking at the wallpaper.
    public void Locked() { if (Config.AutoUpdate && ready != null) Install(); }

    void Set(string s) { State = s; Changed?.Invoke(); }
}
