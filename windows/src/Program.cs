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

    /// The walls are web pages drawn by Microsoft Edge WebView2. Windows 11 always has it; some Windows 10 PCs don't (the
    /// installer adds it, but it can be removed): say so, and offer Microsoft's download, rather than show nothing.
    static bool WebViewReady()
    {
        try { Microsoft.Web.WebView2.Core.CoreWebView2Environment.GetAvailableBrowserVersionString(); return true; }
        catch (Microsoft.Web.WebView2.Core.WebView2RuntimeNotFoundException)
        {
            Log.Write("JSERR WebView2 isn't installed");
            if (Args.Has("--background")) return false;
            var answer = MessageBox.Show("Tidewall draws its walls with Microsoft Edge WebView2, which isn't on this PC.\n\nDownload it from Microsoft now? (It takes a minute; then open Tidewall again.)",
                "Tidewall", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
            if (answer == DialogResult.Yes)
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("https://go.microsoft.com/fwlink/p/?LinkId=2124703") { UseShellExecute = true });
            return false;
        }
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
        if (!WebViewReady()) return;
        Application.ThreadException += (_, e) => Log.Write($"CRASH {e.Exception}");
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Log.Write($"CRASH {e.ExceptionObject}");
        var app = new TidewallApp();
        if (Args.Has("--test")) TestRun.Start(app);
        Application.Run(app);
    }
}
