using System.Diagnostics;

namespace Tidewall;

/// What Tidewall costs: CPU and memory of this process and the browser processes behind the walls (WebView2's, found
/// by their data folder: Windows' Widgets and Search run WebView2 too), and their GPU from Windows' own GPU counters.
/// Measured between two calls; the Settings window's own processes can be counted apart.
internal sealed class Usage
{
    readonly Dictionary<int, TimeSpan> cpuBefore = [];
    readonly Dictionary<string, PerformanceCounter> gpu = [];
    DateTime at = DateTime.UtcNow;
    bool gpuMissing;

    /// AvgCpu: the walls' CPU over about the last minute (from the marks), or -1 before there's a minute to go on.
    public sealed record Sample(double Cpu, double Gpu, double MemMB, double WindowCpu, double WindowMemMB, double AvgCpu = -1);

    readonly Queue<(DateTime At, double CpuSeconds)> marks = new();

    static HashSet<int> Pids()
    {
        var pids = new HashSet<int> { Environment.ProcessId };
        try { foreach (var p in Wallpaper.SharedEnvironment?.GetProcessInfos() ?? []) pids.Add(p.ProcessId); } catch (Exception) { }
        return pids;
    }

    static double CpuSeconds(IEnumerable<int> pids, ICollection<int>? except)
    {
        double s = 0;
        foreach (var pid in pids)
        {
            if (except != null && except.Contains(pid)) continue;
            try { using var p = Process.GetProcessById(pid); s += p.TotalProcessorTime.TotalSeconds; } catch (Exception) { }
        }
        return s;
    }

    /// A note of the CPU used so far (every 15 s, as on the Mac: a cheap read), so the menu can say what the last minute
    /// cost rather than the last instant. `window`: the Settings window's processes, left out.
    public void Mark(ICollection<int>? window = null)
    {
        marks.Enqueue((DateTime.UtcNow, CpuSeconds(Pids(), window)));
        while (marks.Count > 5) marks.Dequeue();                          // (about a minute: five marks 15 s apart)
    }

    /// `window`: the Settings window's processes (its browser process and children), measured apart.
    public Sample Measure(ICollection<int>? window = null)
    {
        var now = DateTime.UtcNow; double dt = Math.Max(.5, (now - at).TotalSeconds); at = now;
        var pids = Pids();
        double avg = -1;
        if (marks.Count > 0 && (now - marks.Peek().At).TotalSeconds >= 30)
            avg = Math.Max(0, (CpuSeconds(pids, window) - marks.Peek().CpuSeconds) / (now - marks.Peek().At).TotalSeconds * 100);
        double cpu = 0, mem = 0, wCpu = 0, wMem = 0;
        foreach (var pid in pids)
        {
            try
            {
                using var p = Process.GetProcessById(pid);
                var t = p.TotalProcessorTime; double c = cpuBefore.TryGetValue(pid, out var was) ? (t - was).TotalSeconds / dt * 100 : 0;
                cpuBefore[pid] = t; double m = p.WorkingSet64 / 1048576.0;
                if (window != null && window.Contains(pid)) { wCpu += c; wMem += m; } else { cpu += c; mem += m; }
            }
            catch (Exception) { cpuBefore.Remove(pid); }
        }
        return new Sample(Math.Round(cpu, 2), Gpu(pids), Math.Round(mem, 1), Math.Round(wCpu, 2), Math.Round(wMem, 1), Math.Round(avg, 2));
    }

    /// Percent of the GPU's busiest engine type our processes use ("GPU Engine" counters; -1 where Windows has none).
    double Gpu(HashSet<int> pids)
    {
        if (gpuMissing) return -1;
        try
        {
            var cat = new PerformanceCounterCategory("GPU Engine");
            var byType = new Dictionary<string, double>();
            foreach (var name in cat.GetInstanceNames())
            {
                int i = name.IndexOf("pid_"), j = name.IndexOf('_', i + 4);
                if (i < 0 || j < 0 || !int.TryParse(name[(i + 4)..j], out int pid) || !pids.Contains(pid)) continue;
                if (!gpu.TryGetValue(name, out var c)) gpu[name] = c = new PerformanceCounter("GPU Engine", "Utilization Percentage", name, true);
                int k = name.IndexOf("engtype_"); var type = k >= 0 ? name[(k + 8)..] : "?";
                byType[type] = byType.GetValueOrDefault(type) + c.NextValue();
            }
            return byType.Count == 0 ? 0 : Math.Round(byType.Values.Max(), 2);
        }
        catch (Exception) { gpuMissing = true; return -1; }
    }
}
