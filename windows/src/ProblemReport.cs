using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace Tidewall;

/// Settings ▸ About ▸ Report a problem, as on the Mac: everything someone fixing it needs (versions, the PC, displays and
/// walls, settings, the end of the log) and nothing that says who or where you are. The issue form opens with the
/// summary; the log goes only on the clipboard, for you to paste in (a URL would hand it to GitHub before you'd sent it).
internal static class ProblemReport
{
    const string NewIssue = "https://github.com/Keshav-Madhav/tidewall/issues/new";

    public static void Send(IReadOnlyList<Wallpaper> walls)
    {
        var summary = Summary(walls);
        var clip = summary + "\n\n### The end of Tidewall's log\n```\n" + LogTail(12_000) + "\n```\n";
        var logNote = "\n\n### The end of Tidewall's log\n<!-- Tidewall copied it to your clipboard: paste it here (Ctrl+V) if you're happy to share it. Your name, folders and location are already taken out. -->\n";
        var url = NewIssue + "?title=" + Uri.EscapeDataString($"Windows {Config.Version}: ") + "&body=" + Uri.EscapeDataString(summary + logNote);
        // TIDEWALL_REPORT_DRYRUN=<file> (tests): the clipboard text goes to that file and the address to the log
        if (Environment.GetEnvironmentVariable("TIDEWALL_REPORT_DRYRUN") is { Length: > 0 } file)
        {
            File.WriteAllText(file, clip);
            Log.Write("[report] " + url);
            return;
        }
        Clipboard.SetText(clip.Replace("\n", Environment.NewLine));
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true });
    }

    static string Summary(IReadOnlyList<Wallpaper> walls)
    {
        string Reg(string key, string value) { try { return Registry.LocalMachine.OpenSubKey(key)?.GetValue(value)?.ToString()?.Trim() ?? "?"; } catch (Exception) { return "?"; } }
        var cv = @"SOFTWARE\Microsoft\Windows NT\CurrentVersion";
        var windows = $"{Reg(cv, "ProductName")} {Reg(cv, "DisplayVersion")} (build {Environment.OSVersion.Version.Build}), {RuntimeInformation.OSArchitecture}";
        var machine = $"{Reg(@"HARDWARE\DESCRIPTION\System\BIOS", "SystemManufacturer")} {Reg(@"HARDWARE\DESCRIPTION\System\BIOS", "SystemProductName")}, {Reg(@"HARDWARE\DESCRIPTION\System\CentralProcessor\0", "ProcessorNameString")}";
        var displays = Display.All.Select(d =>
        {
            var w = walls.FirstOrDefault(x => x.Screen.Name == d.Name);
            var scale = w != null ? $" @{w.PixelScale:0.##}x" : "";
            return $"- {DisplayNames.Of(d) ?? (d.Primary ? "Main display" : "Display")} {d.Bounds.Width}×{d.Bounds.Height}{scale}: {Config.Label(Config.ThemeFor(d))}";
        });
        return Scrub($"""
            ### What happened?
            <!-- What did you see, and what were you doing just before? A screenshot or a short screen recording helps a lot. -->


            ### This PC
            - Tidewall {Config.Version}, {windows}
            - {machine}
            - Graphics: {string.Join(", ", Adapters())}
            {string.Join("\n", displays)}
            - {string.Join(" · ", Settings())}
            """);
    }

    static IEnumerable<string> Settings()
    {
        var reacts = new[] { ("windows", Config.ReactWindows), ("pointer", Config.ReactCursor) }.Where(r => r.Item2).Select(r => r.Item1).ToList();
        return [
            $"frame rate {(Config.Fps == 0 ? "Auto" : ((int)Config.Fps).ToString())}",
            $"on battery {new[] { "same", "calmer", "paused" }[Math.Clamp(Config.Battery, 0, 2)]}",
            $"rest when idle {(Config.IdleMinutes > 0 ? $"{Config.IdleMinutes:0} min" : "never")}",
            $"desktop icons {(Config.DeskIcons ? "on" : "off")}",
            $"reacts to {(reacts.Count > 0 ? string.Join(", ", reacts) : "nothing")}",
            $"span worlds {(Config.SpanWorlds ? "on" : "off")}",
            $"updates {(Config.AutoUpdate ? "automatic" : "manual")}",
            $"paused {(Config.Paused ? "yes" : "no")}",
        ];
    }

    /// The graphics adapters (WARP on a PC or VM with no GPU driver says a lot about frame rates).
    static IEnumerable<string> Adapters()
    {
        var seen = new HashSet<string>();
        var dd = new DISPLAY_DEVICE { cb = Marshal.SizeOf<DISPLAY_DEVICE>() };
        for (uint i = 0; EnumDisplayDevices(null, i, ref dd, 0); i++, dd.cb = Marshal.SizeOf<DISPLAY_DEVICE>())
            if ((dd.StateFlags & 1) != 0 && seen.Add(dd.DeviceString)) yield return dd.DeviceString;   // attached to the desktop
    }

    /// The last lines of the log that fit in `max` characters.
    static string LogTail(int max)
    {
        try
        {
            if (!File.Exists(Log.Path)) return "(no log yet)";
            using var f = new FileStream(Log.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            long back = Math.Min(f.Length, 150_000); f.Seek(-back, SeekOrigin.End);
            var lines = new StreamReader(f).ReadToEnd().Split('\n').Select(l => l.TrimEnd('\r')).ToList();
            if (back < f.Length && lines.Count > 0) lines.RemoveAt(0);         // (read from mid-line: the first is a fragment)
            var kept = new List<string>(); int used = 0;
            for (int i = lines.Count - 1; i >= 0; i--)
            {
                var line = lines[i].Length > 300 ? lines[i][..300] : lines[i];
                if (used + line.Length + 1 > max) break;
                kept.Add(line); used += line.Length + 1;
            }
            kept.Reverse();
            return Scrub(string.Join("\n", kept));
        }
        catch (Exception e) { return $"(the log couldn't be read: {e.GetType().Name})"; }
    }

    /// No home folder, account or full name (any part of it, any case), place, time zone or coordinates (the walls'
    /// addresses carry the place for the weather and the sky, and Wind Map's region is your country).
    static string Scrub(string s)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var t = home.Length > 3 ? s.Replace(home, "~", StringComparison.OrdinalIgnoreCase) : s;
        t = Regex.Replace(t, @"[A-Za-z]:\\Users\\[^\\\s:]+", @"C:\Users\<you>", RegexOptions.IgnoreCase);
        t = ScrubNames(t);
        if (Home.Current is { } p)
            foreach (var form in new[] { p.Tz, p.Name, p.Name.Replace(' ', '_'), Uri.EscapeDataString(p.Tz), Uri.EscapeDataString(p.Name) }.Where(f => f.Length >= 3).Distinct())
                t = Regex.Replace(t, Regex.Escape(form), "<place>", RegexOptions.IgnoreCase);
        t = Regex.Replace(t, @"([?&;])(site|lat|lon|latitude|longitude|tz|timezone|v|region)=[^&\s:]*", "$1$2=…");
        return t;
    }

    /// The account name however a path mangles it (jo_smith as jo-smith or jo.smith), then the full name and each part
    /// of it: 4 letters or more matched even inside other words, 3 only as a word of its own ("Ann" leaves "annotation").
    static string ScrubNames(string s)
    {
        var t = s;
        static string Flexible(string name) => string.Concat(name.Select(c => "_-. ".Contains(c) ? "[-_. ]?" : Regex.Escape(c.ToString())));
        var full = FullName();
        foreach (var name in new[] { Environment.UserName, full }.Where(n => n.Length >= 3))
            t = Regex.Replace(t, Flexible(name), "<you>", RegexOptions.IgnoreCase);
        foreach (var part in full.Split(c => !char.IsLetter(c)).Where(x => x.Length >= 3).Distinct().OrderByDescending(x => x.Length))
            t = Regex.Replace(t, part.Length >= 4 ? Regex.Escape(part) : $"(?<![A-Za-z]){Regex.Escape(part)}(?![A-Za-z])", "<you>", RegexOptions.IgnoreCase);
        return t;
    }

    static string FullName()
    {
        var sb = new StringBuilder(256); uint n = (uint)sb.Capacity;
        try { return GetUserNameEx(3, sb, ref n) ? sb.ToString() : ""; } catch (Exception) { return ""; }   // NameDisplay
    }

    static string[] Split(this string s, Func<char, bool> separator)
    {
        var parts = new List<string>(); var cur = new StringBuilder();
        foreach (var c in s) { if (separator(c)) { if (cur.Length > 0) parts.Add(cur.ToString()); cur.Clear(); } else cur.Append(c); }
        if (cur.Length > 0) parts.Add(cur.ToString());
        return [.. parts];
    }

    [DllImport("secur32.dll", CharSet = CharSet.Unicode)] static extern bool GetUserNameEx(int format, StringBuilder name, ref uint size);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string? device, uint index, ref DISPLAY_DEVICE dd, uint flags);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
}
