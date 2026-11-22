using Velopack;

namespace Tidewall;

internal static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        // the installer's hooks first (install, update, uninstall): uninstalling also takes Tidewall out of "Start with Windows"
        VelopackApp.Build().OnBeforeUninstallFastCallback(_ => LoginItem.Enabled = false).Run();
        Args.Init(args);
        Config.Load();
        Log.Init();
        using var single = new Mutex(true, Args.Has("--test") ? "Tidewall.Test" : "Tidewall.Single", out bool first);
        if (!first) return;
        ApplicationConfiguration.Initialize();
        Application.ThreadException += (_, e) => Log.Write($"CRASH {e.Exception}");
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Log.Write($"CRASH {e.ExceptionObject}");
        var app = new TidewallApp();
        if (Args.Has("--test")) TestRun.Start(app);
        Application.Run(app);
    }
}
