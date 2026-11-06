#!/usr/bin/env python3
"""Draws the chart of a soak run (tools/load_test.gd --soak) as a standalone SVG.

Usage: python -I tools/soak_chart.py <soak_..._series.json> [output.svg]

The input is the series that the soak writes: one sample every 10 s with the tick p99, the static memory, the object
count and the players. The chart has two panels that share the time axis: the memory (MB) with the object count, and the
tick p99 (ms) with the number of players. No dependencies: it writes the SVG by hand (the file opens in any browser and
can be turned into a PNG for a devlog with any converter).
"""
import json
import sys

WIDTH, HEIGHT = 1100, 700
LEFT, RIGHT, TOP = 80, 90, 50
PANEL_HEIGHT, GAP = 250, 70
BACKGROUND, TEXT, GRID = "#14161a", "#d8dce2", "#2c3037"
BLUE, ORANGE, GREEN = "#5aa9ff", "#ffb454", "#7fd18b"


def scale(value, low, high, a, b):
    if high == low:
        return (a + b) / 2
    return a + (value - low) / (high - low) * (b - a)


def polyline(points, color, width=1.5):
    path = " ".join("%.1f,%.1f" % point for point in points)
    return '<polyline fill="none" stroke="%s" stroke-width="%s" points="%s"/>' % (color, width, path)


def panel(series, top, left_key, left_scale, left_label, left_color, right_key, right_label, right_color, title):
    x_end = WIDTH - RIGHT
    bottom = top + PANEL_HEIGHT
    t_max = max(sample["t"] for sample in series) or 1.0
    left_values = [sample[left_key] * left_scale for sample in series]
    right_values = [sample[right_key] for sample in series]
    left_low, left_high = min(left_values), max(left_values)
    pad = (left_high - left_low) * 0.1 or 1.0
    left_low, left_high = left_low - pad, left_high + pad
    right_low, right_high = 0, max(right_values) * 1.15 or 1
    out = ['<text x="%d" y="%d" fill="%s" font-size="15" font-weight="bold">%s</text>' % (LEFT, top - 12, TEXT, title)]
    for step in range(5):
        y = top + PANEL_HEIGHT * step / 4
        out.append('<line x1="%d" y1="%.1f" x2="%d" y2="%.1f" stroke="%s"/>' % (LEFT, y, x_end, y, GRID))
        left_tick = left_high - (left_high - left_low) * step / 4
        right_tick = right_high - (right_high - right_low) * step / 4
        out.append('<text x="%d" y="%.1f" fill="%s" font-size="11" text-anchor="end">%.1f</text>' % (LEFT - 6, y + 4, left_color, left_tick))
        out.append('<text x="%d" y="%.1f" fill="%s" font-size="11">%.0f</text>' % (x_end + 6, y + 4, right_color, right_tick))
    for minutes in range(0, int(t_max // 60) + 1, max(int(t_max // 60 // 8), 1)):
        x = scale(minutes * 60, 0, t_max, LEFT, x_end)
        out.append('<text x="%.1f" y="%d" fill="%s" font-size="11" text-anchor="middle">%d min</text>' % (x, bottom + 16, TEXT, minutes))
    right_points = [(scale(s["t"], 0, t_max, LEFT, x_end), scale(s[right_key], right_low, right_high, bottom, top)) for s in series]
    left_points = [(scale(s["t"], 0, t_max, LEFT, x_end), scale(s[left_key] * left_scale, left_low, left_high, bottom, top)) for s in series]
    out.append(polyline(right_points, right_color, 1.0))
    out.append(polyline(left_points, left_color, 2.0))
    out.append('<text x="%d" y="%d" fill="%s" font-size="12">%s</text>' % (LEFT, bottom + 34, left_color, left_label))
    out.append('<text x="%d" y="%d" fill="%s" font-size="12" text-anchor="end">%s</text>' % (x_end, bottom + 34, right_color, right_label))
    return out


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    with open(sys.argv[1], encoding="utf8") as handle:
        series = json.load(handle)
    if len(series) < 2:
        sys.exit("the series has fewer than two samples")
    output = sys.argv[2] if len(sys.argv) > 2 else sys.argv[1].rsplit(".", 1)[0] + ".svg"
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" font-family="sans-serif">'
             % (WIDTH, HEIGHT, WIDTH, HEIGHT),
             '<rect width="100%%" height="100%%" fill="%s"/>' % BACKGROUND,
             '<text x="%d" y="28" fill="%s" font-size="18" font-weight="bold">Eldmark zone soak: memory and tick p99</text>' % (LEFT, TEXT)]
    parts += panel(series, TOP + 20, "static_memory", 1.0 / 1048576.0, "static memory (MB)", BLUE,
                   "object_count", "objects", ORANGE, "Memory")
    parts += panel(series, TOP + 20 + PANEL_HEIGHT + GAP, "p99_us", 1.0 / 1000.0, "tick p99 (ms)", GREEN,
                   "players", "players", BLUE, "Tick p99")
    parts.append("</svg>")
    with open(output, "w", encoding="utf8") as handle:
        handle.write("\n".join(parts))
    print("chart written to", output)


if __name__ == "__main__":
    main()
