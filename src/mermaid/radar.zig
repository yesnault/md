//! Syntax Ref: https://mermaid.ai/open-source/syntax/radar.html
//!
//! Axes radiate at even angles from a centre, first one at the top, clockwise.
//! Each curve joins one vertex per axis at a value-proportional radius. The
//! terminal's ~2:1 cell aspect needs separate x/y radii. Aliasing is inherent:
//! a polar plot in text cells is coarse.

const std = @import("std");
const Canvas = @import("canvas.zig").Canvas;
const width = @import("../markdown/width.zig");
const text = @import("text.zig");

const ws = text.ws;
const Rx: usize = 18;
const Ry: usize = 9;
const pad_x: usize = 14; // room for axis labels on the sides
const pad_y: usize = 2;

const Curve = struct { name: []const u8, values: []f64 };

pub fn render(arena: std.mem.Allocator, src: []const u8, ascii: bool) ![]const u8 {
    var title: []const u8 = "";
    var axes: std.ArrayList([]const u8) = .empty;
    var curves: std.ArrayList(Curve) = .empty;
    var vmin: f64 = 0;
    var vmax: ?f64 = null;

    var it = text.BodyLines.init(src); // skips "radar" / "radar-beta", blanks, %%
    while (it.next()) |ln| {
        const t = ln.text;
        if (std.mem.startsWith(u8, t, "title ")) {
            title = stripQuotes(std.mem.trim(u8, t[6..], ws));
            continue;
        }
        if (std.mem.startsWith(u8, t, "axis ")) {
            const parts = try splitTop(arena, t[5..]);
            for (parts.items) |p| {
                const lbl = bracketLabel(std.mem.trim(u8, p, ws));
                if (lbl.len > 0) try axes.append(arena, lbl);
            }
            continue;
        }
        if (std.mem.startsWith(u8, t, "curve ")) {
            const head = std.mem.trim(u8, t[6..], ws);
            const name = bracketLabel(head);
            const vals = try parseBraceNums(arena, head);
            if (vals.len > 0) try curves.append(arena, .{ .name = name, .values = vals });
            continue;
        }
        if (std.mem.startsWith(u8, t, "max ")) {
            vmax = std.fmt.parseFloat(f64, std.mem.trim(u8, t[4..], ws)) catch null;
            continue;
        }
        if (std.mem.startsWith(u8, t, "min ")) {
            vmin = std.fmt.parseFloat(f64, std.mem.trim(u8, t[4..], ws)) catch vmin;
            continue;
        }
    }
    const n = axes.items.len;
    if (n == 0 or curves.items.len == 0) return error.Empty;

    var hi: f64 = vmax orelse 0;
    if (vmax == null) for (curves.items) |cv| for (cv.values) |v| {
        hi = @max(hi, v);
    };
    if (hi <= vmin) hi = vmin + 1;

    const cx = pad_x + Rx;
    const cy = pad_y + Ry;
    const canvas_w = cx + Rx + pad_x;
    const legend_y = cy + Ry + 2;
    const canvas_h = legend_y + curves.items.len;
    var c = try Canvas.init(arena, canvas_w, canvas_h);

    const spoke: u21 = if (ascii) '.' else '\u{00B7}'; // ·
    const center: u21 = if (ascii) '+' else '\u{253C}'; // ┼

    // Axis spokes + labels.
    for (axes.items, 0..) |label, k| {
        const th = angle(k, n);
        const rim = point(cx, cy, 1.0, th);
        c.plotLine(cx, cy, rim.x, rim.y, spoke);
        placeLabel(c, rim.x, rim.y, th, clip(label, pad_x));
    }
    c.set(cx, cy, center);

    // Curves: polygon edges then vertex markers (markers on top).
    for (curves.items, 0..) |cv, ci| {
        const glyph = curveGlyph(ci, ascii);
        const m = @min(cv.values.len, n);
        if (m == 0) continue;
        var prev = point(cx, cy, frac(cv.values[0], vmin, hi), angle(0, n));
        var k: usize = 1;
        while (k <= m) : (k += 1) {
            const idx = k % m;
            const cur = point(cx, cy, frac(cv.values[idx], vmin, hi), angle(idx, n));
            c.plotLine(prev.x, prev.y, cur.x, cur.y, glyph);
            prev = cur;
        }
        for (0..m) |j| {
            const p = point(cx, cy, frac(cv.values[j], vmin, hi), angle(j, n));
            c.set(p.x, p.y, glyph);
        }
    }

    // Legend.
    for (curves.items, 0..) |cv, ci| {
        const glyph = curveGlyph(ci, ascii);
        c.set(2, legend_y + ci, glyph);
        c.putStr(4, legend_y + ci, clip(cv.name, canvas_w - 5));
    }

    const body = try c.toString(ascii);
    if (title.len > 0) return std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ title, body });
    return body;
}

const Pt = struct { x: usize, y: usize };

/// angle of axis k of n: first axis at the top, going clockwise.
fn angle(k: usize, n: usize) f64 {
    const kf: f64 = @floatFromInt(k);
    const nf: f64 = @floatFromInt(n);
    return -std.math.pi / 2.0 + 2.0 * std.math.pi * kf / nf;
}

/// point at radius fraction `r` (0..1) along angle `th` from the centre, using
/// separate x/y radii to correct the terminal cell aspect.
fn point(cx: usize, cy: usize, r: f64, th: f64) Pt {
    const dx = @as(f64, @floatFromInt(Rx)) * r * std.math.cos(th);
    const dy = @as(f64, @floatFromInt(Ry)) * r * std.math.sin(th);
    const x = @as(i64, @intCast(cx)) + @as(i64, @intFromFloat(@round(dx)));
    const y = @as(i64, @intCast(cy)) + @as(i64, @intFromFloat(@round(dy)));
    return .{ .x = @intCast(@max(0, x)), .y = @intCast(@max(0, y)) };
}

fn frac(v: f64, lo: f64, hi: f64) f64 {
    return @max(0.0, @min(1.0, (v - lo) / (hi - lo)));
}

/// An axis label just outside its rim point: to the right on the right half,
/// right-aligned on the left half, centred at top and bottom.
fn placeLabel(c: Canvas, rx: usize, ry: usize, th: f64, label: []const u8) void {
    const co = std.math.cos(th);
    const lw = width.displayWidth(label);
    if (co > 0.3) {
        c.putStr(rx + 1, ry, label);
    } else if (co < -0.3) {
        const start = if (rx > lw) rx - lw else 0;
        c.putStr(start, ry, label);
    } else {
        const start = if (rx > lw / 2) rx - lw / 2 else 0;
        c.putStr(start, ry, label);
    }
}

fn curveGlyph(i: usize, ascii: bool) u21 {
    const uni = [_]u21{ '\u{25CF}', '\u{25C6}', '\u{25B2}', '\u{25A0}', '\u{2605}' }; // ● ◆ ▲ ■ ★
    const asc = [_]u21{ 'o', '*', '+', 'x', '#' };
    return if (ascii) asc[i % asc.len] else uni[i % uni.len];
}

/// Splits on top-level commas, ignoring those inside `"..."` or `[...]`.
fn splitTop(arena: std.mem.Allocator, s: []const u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    var depth: usize = 0;
    var in_q = false;
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (ch == '"') in_q = !in_q else if (!in_q and ch == '[') depth += 1 else if (!in_q and ch == ']') {
            if (depth > 0) depth -= 1;
        } else if (!in_q and depth == 0 and ch == ',') {
            try out.append(arena, s[start..i]);
            start = i + 1;
        }
    }
    try out.append(arena, s[start..]);
    return out;
}

/// The text inside `["..."]` when present, else the token up to `[`/`{`, which is an
/// id with no label. Surrounding quotes are stripped.
fn bracketLabel(token: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, token, '[')) |o| {
        const cl = std.mem.indexOfScalarPos(u8, token, o + 1, ']') orelse token.len;
        return stripQuotes(std.mem.trim(u8, token[o + 1 .. cl], ws));
    }
    const stop = std.mem.indexOfAny(u8, token, "{") orelse token.len;
    return stripQuotes(std.mem.trim(u8, token[0..stop], ws));
}

fn parseBraceNums(arena: std.mem.Allocator, s: []const u8) ![]f64 {
    var out: std.ArrayList(f64) = .empty;
    const o = std.mem.indexOfScalar(u8, s, '{') orelse return out.items;
    const cl = std.mem.indexOfScalarPos(u8, s, o + 1, '}') orelse return out.items;
    var ci = std.mem.splitScalar(u8, s[o + 1 .. cl], ',');
    while (ci.next()) |cell| {
        const v = std.fmt.parseFloat(f64, std.mem.trim(u8, cell, ws)) catch continue;
        try out.append(arena, v);
    }
    return out.items;
}

const stripQuotes = text.stripQuotes;
const clip = text.clip;

test "radar plots axes, curve markers, legend and title" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "radar-beta\n" ++
        "title Grades\n" ++
        "axis a[\"Math\"], b[\"English\"], c[\"Science\"]\n" ++
        "curve s1[\"Student A\"]{80, 90, 70}\n" ++
        "max 100\n";
    const art = try render(arena.allocator(), src, false);
    for ([_][]const u8{ "Grades", "Math", "English", "Science", "Student A" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, art, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{25CF}") != null); // curve marker ●
}

test "radar ascii mode uses o markers, no unicode glyphs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "radar-beta\n" ++
        "axis a[\"A\"], b[\"B\"], c[\"C\"], d[\"D\"]\n" ++
        "curve s1[\"One\"]{1, 2, 3, 4}\n" ++
        "curve s2[\"Two\"]{4, 3, 2, 1}\n";
    const art = try render(arena.allocator(), src, true);
    try std.testing.expect(std.mem.indexOf(u8, art, "o") != null); // first curve ascii marker
    try std.testing.expect(std.mem.indexOf(u8, art, "One") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "Two") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{25CF}") == null); // no unicode marker ●
}
