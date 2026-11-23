namespace Tidewall;

/// One display's part in a world spanning several: where it sits in the world, in points (its pixels ÷ its own scale,
/// as macOS lays out displays), so a laptop at 150% beside a monitor at 100% still make one continuous world.
internal sealed record WorldPart(Display Screen, double Scale, RectangleF Points)
{
    /// A point on this display (screen pixels) in the world's points.
    public PointF ToPoints(Point p) => new((float)(Points.X + (p.X - Screen.Bounds.X) / Scale), (float)(Points.Y + (p.Y - Screen.Bounds.Y) / Scale));
}

internal static class World
{
    /// Windows places displays edge to edge in physical pixels, each with its own scale, so there's no one unit across
    /// them. As on a Mac, each is measured in points instead: the main display where it is, and each other one against
    /// the edge it shares with one already placed (its offset along that edge in its neighbour's points), so neighbours
    /// stay flush, with no gap or overlap. One that touches none keeps its own position ÷ its scale.
    public static IReadOnlyList<WorldPart> Layout(IReadOnlyList<(Display Screen, double Scale)> displays)
    {
        if (displays.Count == 0) return [];
        var placed = new List<WorldPart>();
        var first = displays.FirstOrDefault(d => d.Screen.Primary);
        if (first.Screen == null) first = displays[0];
        placed.Add(new WorldPart(first.Screen, first.Scale, Own(first)));
        var left = displays.Where(d => d.Screen != first.Screen).ToList();
        while (left.Count > 0)
        {
            bool progress = false;
            foreach (var d in left.ToList())
            {
                foreach (var p in placed)
                {
                    if (Against(d, p) is not { } at) continue;
                    placed.Add(new WorldPart(d.Screen, d.Scale, at)); left.Remove(d); progress = true;
                    break;
                }
            }
            if (!progress) { foreach (var d in left) placed.Add(new WorldPart(d.Screen, d.Scale, Own(d))); break; }
        }
        // in the order they were given
        return displays.Select(d => placed.First(p => p.Screen == d.Screen)).ToList();
    }

    static RectangleF Own((Display Screen, double Scale) d)
    {
        var b = d.Screen.Bounds; var k = d.Scale;
        return new RectangleF((float)(b.X / k), (float)(b.Y / k), (float)(b.Width / k), (float)(b.Height / k));
    }

    /// Where d sits in points if it shares an edge with p (a pixel or two of slack), else nothing.
    static RectangleF? Against((Display Screen, double Scale) d, WorldPart p)
    {
        Rectangle a = d.Screen.Bounds, b = p.Screen.Bounds;
        float w = (float)(a.Width / d.Scale), h = (float)(a.Height / d.Scale);
        bool Near(int x, int y) => Math.Abs(x - y) <= 2;
        bool rows = a.Top < b.Bottom && a.Bottom > b.Top, cols = a.Left < b.Right && a.Right > b.Left;
        float alongY = (float)(p.Points.Y + (a.Y - b.Y) / p.Scale), alongX = (float)(p.Points.X + (a.X - b.X) / p.Scale);
        if (rows && Near(a.Left, b.Right)) return new RectangleF(p.Points.Right, alongY, w, h);
        if (rows && Near(a.Right, b.Left)) return new RectangleF(p.Points.Left - w, alongY, w, h);
        if (cols && Near(a.Top, b.Bottom)) return new RectangleF(alongX, p.Points.Bottom, w, h);
        if (cols && Near(a.Bottom, b.Top)) return new RectangleF(alongX, p.Points.Top - h, w, h);
        return null;
    }
}
