namespace Tidewall;

/// Whether windows cover an area (as the macOS app's isCovered): less than one pixel of it shows past them. The union of
/// the rectangles by coordinate compression, stopping as soon as the answer is known; a sliver between two windows counts.
internal static class Covered
{
    public static bool IsCovered(Rectangle area, IEnumerable<Rectangle> windows)
    {
        var rs = windows.Select(r => Rectangle.Intersect(r, area)).Where(r => r.Width > 0 && r.Height > 0).ToList();
        if (rs.Count == 0) return area.Width * area.Height < 1;
        if (rs.Any(r => r.Contains(area))) return true;
        var xs = rs.SelectMany(r => new[] { r.Left, r.Right }).Append(area.Left).Append(area.Right).Distinct().Order().ToArray();
        var ys = rs.SelectMany(r => new[] { r.Top, r.Bottom }).Append(area.Top).Append(area.Bottom).Distinct().Order().ToArray();
        long free = 0;
        for (int i = 0; i < xs.Length - 1; i++)
            for (int j = 0; j < ys.Length - 1; j++)
            {
                double cx = (xs[i] + xs[i + 1]) / 2.0, cy = (ys[j] + ys[j + 1]) / 2.0;
                if (!rs.Any(r => cx >= r.Left && cx < r.Right && cy >= r.Top && cy < r.Bottom))
                {
                    free += (long)(xs[i + 1] - xs[i]) * (ys[j + 1] - ys[j]);
                    if (free >= 1) return false;
                }
            }
        return true;
    }
}
