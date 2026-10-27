Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;

public static class CheckerKeyer
{
    static bool IsGray(Color c, int maxChroma, int minBright, int maxBright)
    {
        int max = Math.Max(c.R, Math.Max(c.G, c.B));
        int min = Math.Min(c.R, Math.Min(c.G, c.B));
        int bright = (c.R + c.G + c.B) / 3;
        return (max - min) <= maxChroma && bright >= minBright && bright <= maxBright;
    }

    static bool Matches(Color c, List<Color> targets, int tol)
    {
        foreach (Color t in targets)
        {
            if (Math.Abs(c.R - t.R) <= tol && Math.Abs(c.G - t.G) <= tol && Math.Abs(c.B - t.B) <= tol)
                return true;
        }
        return false;
    }

    static string Hex(Color c)
    {
        return string.Format("#{0:X2}{1:X2}{2:X2}", c.R, c.G, c.B);
    }

    public static string Run(string inPath, string outPath)
    {
        const int tol = 6;

        using (Bitmap loaded = new Bitmap(inPath))
        using (Bitmap bmp = new Bitmap(loaded.Width, loaded.Height, PixelFormat.Format32bppArgb))
        {
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.DrawImage(loaded, 0, 0, loaded.Width, loaded.Height);
            }

            int w = bmp.Width;
            int h = bmp.Height;

            // 1. The checkerboard is the two most common grayish colors in the image.
            Dictionary<int, int> counts = new Dictionary<int, int>();
            for (int y = 0; y < h; y++)
            {
                for (int x = 0; x < w; x++)
                {
                    Color c = bmp.GetPixel(x, y);
                    if (!IsGray(c, 6, 90, 235)) continue;
                    int key = c.ToArgb();
                    int n;
                    counts.TryGetValue(key, out n);
                    counts[key] = n + 1;
                }
            }

            List<KeyValuePair<int, int>> ranked = new List<KeyValuePair<int, int>>(counts);
            ranked.Sort((a, b) => b.Value.CompareTo(a.Value));
            if (ranked.Count < 2) return "Not enough gray colors found.";

            Color first = Color.FromArgb(ranked[0].Key);
            Color second = Color.FromArgb(ranked[1].Key);
            List<Color> targets = new List<Color> { first, second };

            // 2. Flood fill from the image edge through the checkerboard colors.
            // Background enclosed by the character is not reached, so it stays opaque.
            bool[] visited = new bool[w * h];
            Queue<int> queue = new Queue<int>();

            List<int> seeds = new List<int>();
            for (int x = 0; x < w; x++)
            {
                seeds.Add(x);
                seeds.Add((h - 1) * w + x);
            }
            for (int y = 0; y < h; y++)
            {
                seeds.Add(y * w);
                seeds.Add(y * w + (w - 1));
            }
            foreach (int s in seeds)
            {
                if (visited[s]) continue;
                if (!Matches(bmp.GetPixel(s % w, s / w), targets, tol)) continue;
                visited[s] = true;
                queue.Enqueue(s);
            }

            int[] dx = { 1, -1, 0, 0 };
            int[] dy = { 0, 0, 1, -1 };
            int removed = 0;
            while (queue.Count > 0)
            {
                int idx = queue.Dequeue();
                int x = idx % w;
                int y = idx / w;
                Color c = bmp.GetPixel(x, y);
                bmp.SetPixel(x, y, Color.FromArgb(0, c.R, c.G, c.B));
                removed++;

                for (int k = 0; k < 4; k++)
                {
                    int nx = x + dx[k];
                    int ny = y + dy[k];
                    if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                    int ni = ny * w + nx;
                    if (visited[ni]) continue;
                    if (!Matches(bmp.GetPixel(nx, ny), targets, tol)) continue;
                    visited[ni] = true;
                    queue.Enqueue(ni);
                }
            }

            bmp.Save(outPath, ImageFormat.Png);

            return string.Format("Size {0}x{1}. Checker colors {2} and {3}. Keyed out {4} pixels. Saved {5}",
                w, h, Hex(first), Hex(second), removed, outPath);
        }
    }
}
"@

[CheckerKeyer]::Run("$PWD\assets\character.png", "$PWD\assets\character_clean.png")
