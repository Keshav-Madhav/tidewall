namespace Tidewall;

/// A display a wall is drawn on. Real ones come from Windows; --fakescreens N (tests) splits the main display into N
/// side by side, each a display of its own to the walls, so one world across displays can be tried on one screen.
internal sealed record Display(string Name, string Device, Rectangle Bounds, Rectangle WorkingArea, bool Primary)
{
    public static IReadOnlyList<Display> All
    {
        get
        {
            var screens = Screen.AllScreens;
            if (Args.Value("--fakescreens") is not { } v || !int.TryParse(v, out int n) || n < 2)
                return screens.Select(s => new Display(s.DeviceName, s.DeviceName, s.Bounds, s.WorkingArea, s.Primary)).ToList();
            var p = Screen.PrimaryScreen ?? screens[0];
            var list = new List<Display>();
            for (int i = 0; i < n; i++)
            {
                int x0 = p.Bounds.X + p.Bounds.Width * i / n, x1 = p.Bounds.X + p.Bounds.Width * (i + 1) / n;
                var b = Rectangle.FromLTRB(x0, p.Bounds.Y, x1, p.Bounds.Bottom);
                list.Add(new Display($@"\\.\FAKE{i + 1}", p.DeviceName, b, Rectangle.Intersect(b, p.WorkingArea), i == 0));
            }
            return list;
        }
    }
}
