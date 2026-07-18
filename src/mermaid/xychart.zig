//! Syntax Ref: https://mermaid.ai/open-source/syntax/xyChart.html
//!
//! Bar and line series can both be present. The `horizontal` header keyword swaps
//! the axes: categories down the left, bars extending rightward.

const std = @import("std");
const Canvas = @import("canvas.zig").Canvas;
const putCentered = @import("canvas.zig").putCentered;
const width = @import("../markdown/width.zig");
const text = @import("text.zig");

const ws = text.ws;
const gutter: usize = 8; // y-axis label (col 0) + numeric ticks
const plot_h: usize = 15; // plotting band height in rows
const col_w: usize = 7; // columns per category
const plot_w: usize = 36; // horizontal mode: plotting band width in columns
const cat_row_h: usize = 2; // horizontal mode: rows per category (bar + spacer)

/// Chart is the parsed spec with its value range resolved.
const Chart = struct {
    title: []const u8 = "",
    y_label: []const u8 = "",
    cats: []const []const u8 = &.{},
    bar: ?[]f64 = null,
    line: ?[]f64 = null,
    lo: f64 = 0,
    hi: f64 = 1,
    n: usize = 0, // category count (longest series)
    horizontal: bool = false,
};

pub fn render(arena: std.mem.Allocator, src: []const u8, ascii: bool) ![]const u8 {
    const chart = try parse(arena, src);
    const body = if (chart.horizontal)
        try drawHorizontal(arena, chart, ascii)
    else
        try draw(arena, chart, ascii);
    if (chart.title.len > 0) return std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ chart.title, body });
    return body;
}

fn parse(arena: std.mem.Allocator, src: []const u8) !Chart {
    var chart = Chart{};
    var cats: std.ArrayList([]const u8) = .empty;
    var y_min: ?f64 = null;
    var y_max: ?f64 = null;

    // The orientation keyword sits on the header line, which BodyLines skips.
    var header = std.mem.splitScalar(u8, src, '\n');
    while (header.next()) |raw| {
        const t = std.mem.trim(u8, raw, ws);
        if (t.len == 0 or std.mem.startsWith(u8, t, "%%")) continue;
        var tok = std.mem.tokenizeAny(u8, t, " \t");
        while (tok.next()) |w| chart.horizontal = chart.horizontal or eqIgnoreCase(w, "horizontal");
        break;
    }

    var it = text.BodyLines.init(src); // skips "xychart[-beta] [horizontal]", blanks, %%
    while (it.next()) |ln| {
        const t = ln.text;
        if (std.mem.startsWith(u8, t, "title ")) {
            chart.title = stripQuotes(std.mem.trim(u8, t[6..], ws));
            continue;
        }
        if (std.mem.startsWith(u8, t, "x-axis ")) {
            if (bracket(t)) |inner| {
                var ci = std.mem.splitScalar(u8, inner, ',');
                while (ci.next()) |cell| try cats.append(arena, stripQuotes(std.mem.trim(u8, cell, ws)));
            }
            continue;
        }
        if (std.mem.startsWith(u8, t, "y-axis ")) {
            var rest = std.mem.trim(u8, t[7..], ws);
            if (rest.len > 0 and rest[0] == '"') {
                if (std.mem.indexOfScalarPos(u8, rest, 1, '"')) |q| {
                    chart.y_label = rest[1..q];
                    rest = std.mem.trim(u8, rest[q + 1 ..], ws);
                }
            }
            if (std.mem.indexOf(u8, rest, "-->")) |a| {
                y_min = std.fmt.parseFloat(f64, std.mem.trim(u8, rest[0..a], ws)) catch null;
                y_max = std.fmt.parseFloat(f64, std.mem.trim(u8, rest[a + 3 ..], ws)) catch null;
            }
            continue;
        }
        if (std.mem.startsWith(u8, t, "bar ")) {
            chart.bar = try parseNums(arena, t);
            continue;
        }
        if (std.mem.startsWith(u8, t, "line ")) {
            chart.line = try parseNums(arena, t);
            continue;
        }
    }
    chart.cats = cats.items;
    const series = chart.bar orelse chart.line orelse return error.Empty;
    chart.n = series.len;
    if (chart.bar) |b| chart.n = @max(chart.n, b.len);
    if (chart.line) |l| chart.n = @max(chart.n, l.len);
    if (chart.n == 0) return error.Empty;

    // Resolve the value range: explicit y-axis wins, else auto (0..max over data,
    // extended to negative data minimums).
    var lo: f64 = 0;
    var hi: f64 = 0;
    var seen = false;
    for ([_]?[]f64{ chart.bar, chart.line }) |maybe| if (maybe) |s| for (s) |v| {
        if (!seen) {
            lo = v;
            hi = v;
            seen = true;
        } else {
            lo = @min(lo, v);
            hi = @max(hi, v);
        }
    };
    if (lo > 0) lo = 0;
    if (y_min) |v| lo = v;
    if (y_max) |v| hi = v;
    if (hi <= lo) hi = lo + 1;
    chart.lo = lo;
    chart.hi = hi;
    return chart;
}

fn draw(arena: std.mem.Allocator, chart: Chart, ascii: bool) ![]const u8 {
    const lo = chart.lo;
    const hi = chart.hi;
    const canvas_w = gutter + chart.n * col_w + 1;
    const canvas_h = plot_h + 2; // band + baseline + category labels
    var c = try Canvas.init(arena, canvas_w, canvas_h);
    const ax = gutter; // y-axis column
    const baseline = plot_h; // x-axis row

    // Axes on the connection layer.
    c.lineV(0, baseline, ax);
    c.lineH(ax, canvas_w - 1, baseline);

    // y-axis numeric ticks (top = hi, bottom = lo, plus a midpoint).
    putRight(c, ax - 1, 0, fmtNum(arena, hi));
    putRight(c, ax - 1, plot_h - 1, fmtNum(arena, lo));
    putRight(c, ax - 1, plot_h / 2, fmtNum(arena, (hi + lo) / 2));
    // y-axis unit label, written vertically down column 0.
    for (chart.y_label, 0..) |ch, i| {
        if (i >= plot_h) break;
        c.set(0, i, ch);
    }

    const block: u21 = if (ascii) '#' else '\u{2588}'; // █
    // Bars.
    if (chart.bar) |b| {
        for (b, 0..) |v, i| {
            const frac = clampUnit((v - lo) / (hi - lo));
            const filled: usize = @intFromFloat(@round(frac * @as(f64, plot_h)));
            const cstart = ax + 1 + i * col_w;
            const bx0 = cstart + 1;
            const bx1 = cstart + col_w - 1;
            var row = plot_h - filled;
            while (row < plot_h) : (row += 1) {
                var x = bx0;
                while (x < bx1) : (x += 1) c.set(x, row, block);
            }
        }
    }
    // Line series: markers joined by diagonal segments.
    if (chart.line) |l| {
        const marker: u21 = if (ascii) '*' else '\u{25CF}'; // ●
        const seg: u21 = if (ascii) '.' else '\u{00B7}'; // ·
        var prev_x: usize = 0;
        var prev_y: usize = 0;
        for (l, 0..) |v, i| {
            const frac = clampUnit((v - lo) / (hi - lo));
            const up: usize = @intFromFloat(@round(frac * @as(f64, plot_h - 1)));
            const py = (plot_h - 1) - up;
            const px = ax + 1 + i * col_w + col_w / 2;
            if (i > 0) c.plotLine(prev_x, prev_y, px, py, seg);
            prev_x = px;
            prev_y = py;
        }
        // Markers drawn after segments so they sit on top.
        for (l, 0..) |v, i| {
            const frac = clampUnit((v - lo) / (hi - lo));
            const up: usize = @intFromFloat(@round(frac * @as(f64, plot_h - 1)));
            const py = (plot_h - 1) - up;
            const px = ax + 1 + i * col_w + col_w / 2;
            c.set(px, py, marker);
        }
    }

    // x-axis category labels, centred under each column.
    for (0..chart.n) |i| {
        const label = if (i < chart.cats.len) chart.cats[i] else "";
        putCentered(c, ax + 1 + i * col_w, col_w, baseline + 1, clip(label, col_w));
    }

    return c.toString(ascii);
}

/// The axis-swapped variant: categories down the left, bars extending rightward,
/// value ticks under the baseline with the value-axis label below them. The line
/// series transposes the same way.
fn drawHorizontal(arena: std.mem.Allocator, chart: Chart, ascii: bool) ![]const u8 {
    const lo = chart.lo;
    const hi = chart.hi;
    const n = chart.n;
    var cat_w: usize = 1;
    for (chart.cats) |cat| cat_w = @max(cat_w, width.displayWidth(cat) + 1);
    const ax = cat_w; // category-axis column
    const baseline = n * cat_row_h - 1; // value-axis row
    const canvas_w = ax + plot_w + 2;
    const canvas_h = baseline + 3; // ticks + value-axis label
    var c = try Canvas.init(arena, canvas_w, canvas_h);

    // Axes on the connection layer.
    c.lineV(0, baseline, ax);
    c.lineH(ax, ax + plot_w, baseline);

    // Category labels, right-aligned against the axis.
    for (0..n) |i| {
        const label = if (i < chart.cats.len) chart.cats[i] else "";
        putRight(c, ax - 1, i * cat_row_h, clip(label, ax - 1));
    }

    const block: u21 = if (ascii) '#' else '\u{2588}'; // █
    // Bars, growing rightward from the axis.
    if (chart.bar) |b| {
        for (b, 0..) |v, i| {
            const frac = clampUnit((v - lo) / (hi - lo));
            const filled: usize = @intFromFloat(@round(frac * @as(f64, plot_w)));
            var x = ax + 1;
            while (x <= ax + filled) : (x += 1) c.set(x, i * cat_row_h, block);
        }
    }
    // Line series: markers joined by diagonal segments.
    if (chart.line) |l| {
        const marker: u21 = if (ascii) '*' else '\u{25CF}'; // ●
        const seg: u21 = if (ascii) '.' else '\u{00B7}'; // ·
        var prev_x: usize = 0;
        var prev_y: usize = 0;
        for (l, 0..) |v, i| {
            const frac = clampUnit((v - lo) / (hi - lo));
            const px = ax + 1 + @as(usize, @intFromFloat(@round(frac * @as(f64, plot_w - 1))));
            const py = i * cat_row_h;
            if (i > 0) c.plotLine(prev_x, prev_y, px, py, seg);
            prev_x = px;
            prev_y = py;
        }
        // Markers drawn after segments so they sit on top.
        for (l, 0..) |v, i| {
            const frac = clampUnit((v - lo) / (hi - lo));
            const px = ax + 1 + @as(usize, @intFromFloat(@round(frac * @as(f64, plot_w - 1))));
            c.set(px, i * cat_row_h, marker);
        }
    }

    // Value ticks under the baseline (left = lo, centre, right = hi), then
    // the value-axis label written horizontally below them.
    c.putStr(ax, baseline + 1, fmtNum(arena, lo));
    putCentered(c, ax, plot_w, baseline + 1, fmtNum(arena, (hi + lo) / 2));
    putRight(c, ax + plot_w, baseline + 1, fmtNum(arena, hi));
    if (chart.y_label.len > 0) c.putStr(ax, baseline + 2, chart.y_label);

    return c.toString(ascii);
}

fn parseNums(arena: std.mem.Allocator, t: []const u8) ![]f64 {
    var out: std.ArrayList(f64) = .empty;
    const inner = bracket(t) orelse return out.items;
    var ci = std.mem.splitScalar(u8, inner, ',');
    while (ci.next()) |cell| {
        const v = std.fmt.parseFloat(f64, std.mem.trim(u8, cell, ws)) catch continue;
        try out.append(arena, v);
    }
    return out.items;
}

fn bracket(t: []const u8) ?[]const u8 {
    const o = std.mem.indexOfScalar(u8, t, '[') orelse return null;
    const cl = std.mem.indexOfScalarPos(u8, t, o + 1, ']') orelse return null;
    return t[o + 1 .. cl];
}

fn clampUnit(v: f64) f64 {
    return @max(0.0, @min(1.0, v));
}

fn fmtNum(arena: std.mem.Allocator, v: f64) []const u8 {
    return text.fmtNum(arena, v, "{d:.1}");
}

fn putRight(c: Canvas, right_x: usize, y: usize, s: []const u8) void {
    const w = width.displayWidth(s);
    const start = if (right_x + 1 > w) right_x + 1 - w else 0;
    c.putStr(start, y, s);
}

const stripQuotes = text.stripQuotes;
const clip = text.clip;
const eqIgnoreCase = text.eqIgnoreCase;

test "xychart renders title, categories, y range and bars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "xychart-beta\n" ++
        "title \"Sales Revenue\"\n" ++
        "x-axis [jan, feb, mar]\n" ++
        "y-axis \"Revenue\" 0 --> 100\n" ++
        "bar [10, 50, 100]\n";
    const art = try render(arena.allocator(), src, false);
    for ([_][]const u8{ "Sales Revenue", "jan", "feb", "mar", "100" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, art, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{2588}") != null); // bar block █
    // The full-height bar (value == max) reaches the top plot row.
    const top = std.mem.indexOfScalar(u8, art, '\n').? + 2; // after "title\n\n"
    try std.testing.expect(std.mem.indexOfPos(u8, art, top, "\u{2588}") != null); // █
}

test "xychart horizontal swaps the axes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "xychart-beta horizontal\n" ++
        "title \"Top products\"\n" ++
        "x-axis [alpha, beta, gamma]\n" ++
        "y-axis \"Units\" 0 --> 100\n" ++
        "bar [30, 75, 100]\n";
    const art = try render(arena.allocator(), src, false);
    // Categories label their own rows on the left of the axis.
    try std.testing.expect(std.mem.indexOf(u8, art, "alpha\u{2502}") != null); // alpha│
    // Bars extend rightward from the axis.
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{2502}\u{2588}") != null); // │█
    // Range ticks and the value-axis label sit under the baseline.
    try std.testing.expect(std.mem.indexOf(u8, art, "100") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "Units") != null);
}

test "xychart ascii bars and a line series with markers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "xychart-beta\n" ++
        "x-axis [a, b, c]\n" ++
        "bar [1, 2, 3]\n" ++
        "line [3, 2, 1]\n";
    const art = try render(arena.allocator(), src, true);
    try std.testing.expect(std.mem.indexOf(u8, art, "#") != null); // ascii bar
    try std.testing.expect(std.mem.indexOf(u8, art, "*") != null); // ascii line marker
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{2588}") == null); // no unicode block in ascii █
}
