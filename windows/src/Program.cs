using Velopack;

namespace Tidewall;

internal static class Program
{
    /// Uninstalling: out of Start with Windows, and the log and the browser's cache gone with the app (your settings, a
    /// small file in Roaming, stay for a reinstall).
    static void Uninstalling()
    {
        LoginItem.Enabled = false;
        TidewallApp.AskRunningToQuit();                                   // (else the uninstaller waits five minutes for it)
        try { if (Directory.Exists(Config.DataDir)) Directory.Delete(Config.DataDir, true); } catch (Exception) { }
    }

    [STAThread]
    static void Main(string[] args)
    {
        // the installer's hooks first (install, update, uninstall): uninstalling also takes Tidewall out of "Start with Windows"
        VelopackApp.Build().OnBeforeUninstallFastCallback(_ => Uninstalling()).Run();
        Args.Init(args);
        Config.Load();
        Log.Init();
        using var single = new Mutex(true, Args.Has("--test") ? "Tidewall.Test" : "Tidewall.Single", out bool first);
        if (!first)
        {
            // already running (opened again from the Start menu, say): that one shows its window; this one goes
            if (!Args.Has("--background") && !Args.Has("--test")) TidewallApp.AskRunningToShowSettings();
            return;
        }
        ApplicationConfiguration.Initialize();
        Application.ThreadException += (_, e) => Log.Write($"CRASH {e.Exception}");
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Log.Write($"CRASH {e.ExceptionObject}");
        var app = new TidewallApp();
        if (Args.Has("--test")) TestRun.Start(app);
        Application.Run(app);
    }
}
