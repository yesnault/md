//! Syntax Ref: https://mermaid.ai/open-source/syntax/quadrantChart.html
//!
//! Mermaid quadrantChart as a 2D scatter plot: a bordered square split by a
//! centre cross, points `Name: [x, y]` with x,y in 0..1.

const std = @import("std");
const Canvas = @import("canvas.zig").Canvas;
const canvas = @import("canvas.zig");
const width = @import("../markdown/width.zig");
const text = @import("text.zig");

const ws = text.ws;

const W: usize = 64; // canvas width
const Bh: usize = 18; // box height (rows)
const box_top: usize = 2;
const box_bot: usize = box_top + Bh - 1; // 19
const H: usize = Bh + 4; // 0:title 1:y_top 2..19:box 20:x labels 21:y_bottom

const Point = struct { name: []const u8, x: f64, y: f64 };

pub fn render(arena: std.mem.Allocator, src: []const u8, ascii: bool) ![]const u8 {
    var title: []const u8 = "";
    var x_left: []const u8 = "";
    var x_right: []const u8 = "";
    var y_bottom: []const u8 = "";
    var y_top: []const u8 = "";
    var q: [4][]const u8 = .{ "", "", "", "" }; // quadrant-1..4
    var points: std.ArrayList(Point) = .empty;

    var it = text.BodyLines.init(src); // skips "quadrantChart", blanks, %%
    while (it.next()) |ln| {
        const t = ln.text;
        if (std.mem.startsWith(u8, t, "title ")) {
            title = std.mem.trim(u8, t[6..], ws);
            continue;
        }
        if (std.mem.startsWith(u8, t, "x-axis ")) {
            axisLabels(t[7..], &x_left, &x_right);
            continue;
        }
        if (std.mem.startsWith(u8, t, "y-axis ")) {
            axisLabels(t[7..], &y_bottom, &y_top);
            continue;
        }
        if (std.mem.startsWith(u8, t, "quadrant-") and t.len > 9) {
            const n = t[9] -% '1';
            if (n < 4) q[n] = stripQuotes(std.mem.trim(u8, t[10..], ws));
            continue;
        }
        if (parsePoint(t)) |p| try points.append(arena, p);
    }
    if (points.items.len == 0) return error.Empty;

    var c = try Canvas.init(arena, W, H);
    const mid_col = W / 2;
    const mid_row = (box_top + box_bot) / 2;
    // Border + centre cross on the line layer. Junctions auto-resolve.
    c.lineH(0, W - 1, box_top);
    c.lineH(0, W - 1, box_bot);
    c.lineV(box_top, box_bot, 0);
    c.lineV(box_top, box_bot, W - 1);
    c.lineV(box_top, box_bot, mid_col);
    c.lineH(0, W - 1, mid_row);

    if (title.len > 0) c.putStr(0, 0, clip(title, W));
    putCentered(c, 0, W - 1, 1, y_top);
    putCentered(c, 0, W - 1, H - 1, y_bottom);
    // x-axis labels below the box: left-aligned and right-aligned.
    if (x_left.len > 0) c.putStr(1, box_bot + 1, clip(x_left, W / 2 - 1));
    if (x_right.len > 0) {
        const xw = @min(width.displayWidth(x_right), W - 2);
        c.putStr(W - 1 - xw, box_bot + 1, clip(x_right, W / 2 - 1));
    }
    // Quadrant labels: 2=top-left, 1=top-right, 3=bottom-left, 4=bottom-right.
    putCentered(c, 1, mid_col - 1, box_top + 2, q[1]);
    putCentered(c, mid_col + 1, W - 2, box_top + 2, q[0]);
    putCentered(c, 1, mid_col - 1, box_bot - 2, q[2]);
    putCentered(c, mid_col + 1, W - 2, box_bot - 2, q[3]);

    const marker: u21 = if (ascii) '*' else '\u{25CF}'; // ●
    for (points.items) |p| {
        const px = 1 + scale(p.x, W - 3);
        const py = box_top + 1 + scale(1 - p.y, Bh - 3);
        c.set(px, py, marker);
        if (px + 2 < W - 1) c.putStr(px + 2, py, clip(p.name, W - 1 - (px + 2)));
    }
    return c.toString(ascii);
}

fn scale(v: f64, span: usize) usize {
    const cl = @max(0.0, @min(1.0, v));
    return @intFromFloat(@round(cl * @as(f64, @floatFromInt(span))));
}

/// "L --> R" (R optional) into trimmed, unquoted ends.
fn axisLabels(spec: []const u8, lo: *[]const u8, hi: *[]const u8) void {
    if (std.mem.indexOf(u8, spec, "-->")) |a| {
        lo.* = stripQuotes(std.mem.trim(u8, spec[0..a], ws));
        hi.* = stripQuotes(std.mem.trim(u8, spec[a + 3 ..], ws));
    } else {
        lo.* = stripQuotes(std.mem.trim(u8, spec, ws));
    }
}

fn parsePoint(t: []const u8) ?Point {
    const ob = std.mem.indexOfScalar(u8, t, '[') orelse return null;
    const cb = std.mem.indexOfScalarPos(u8, t, ob + 1, ']') orelse return null;
    var name = std.mem.trimEnd(u8, t[0..ob], ws);
    name = std.mem.trimEnd(u8, name, ":");
    name = std.mem.trimEnd(u8, name, ws);
    if (std.mem.indexOf(u8, name, ":::")) |s| name = std.mem.trim(u8, name[0..s], ws);
    if (name.len == 0) return null;
    const inner = t[ob + 1 .. cb];
    const comma = std.mem.indexOfScalar(u8, inner, ',') orelse return null;
    const x = std.fmt.parseFloat(f64, std.mem.trim(u8, inner[0..comma], ws)) catch return null;
    const y = std.fmt.parseFloat(f64, std.mem.trim(u8, inner[comma + 1 ..], ws)) catch return null;
    return .{ .name = stripQuotes(name), .x = x, .y = y };
}

const stripQuotes = text.stripQuotes;
const clip = text.clip;

fn putCentered(c: Canvas, a: usize, b: usize, row: usize, s: []const u8) void {
    if (s.len == 0 or b < a) return;
    const span = b - a + 1;
    canvas.putCentered(c, a, span, row, clip(s, span));
}

test "quadrant renders title, quadrant labels and plotted points" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "quadrantChart\n" ++
        "title Reach and engagement\n" ++
        "x-axis Low Reach --> High Reach\n" ++
        "y-axis Low Engagement --> High Engagement\n" ++
        "quadrant-1 Expand\n" ++
        "quadrant-2 Promote\n" ++
        "quadrant-3 Reevaluate\n" ++
        "quadrant-4 Improve\n" ++
        "Campaign A: [0.3, 0.6]\n" ++
        "Campaign B: [0.45, 0.23]\n";
    const art = try render(arena.allocator(), src, false);
    for ([_][]const u8{ "Reach and engagement", "Expand", "Promote", "Campaign A", "High Reach" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, art, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{25CF}") != null); // point marker ●
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{253C}") != null); // centre cross ┼
}

test "quadrant survives a bare quadrant- line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "quadrantChart\nquadrant-\nA: [0.2, 0.8]\n";
    const art = try render(arena.allocator(), src, false);
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{25CF}") != null); // ●
}

test "quadrant ascii mode uses * markers and + junctions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "quadrantChart\nA: [0.2, 0.8]\nB: [0.9, 0.1]\n";
    const art = try render(arena.allocator(), src, true);
    try std.testing.expect(std.mem.indexOf(u8, art, "*") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "+") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{25CF}") == null); // ●
}

test "parsePoint reads name and x,y, stripping quotes and :::class" {
    const p = parsePoint("Campaign A: [0.3, 0.6]").?;
    try std.testing.expectEqualStrings("Campaign A", p.name);
    try std.testing.expectEqual(@as(f64, 0.3), p.x);
    try std.testing.expectEqual(@as(f64, 0.6), p.y);
    const q = parsePoint("\"P1\": [1, 0]").?;
    try std.testing.expectEqualStrings("P1", q.name); // surrounding quotes stripped
    const r = parsePoint("Pt:::hot: [0.5, 0.5]").?;
    try std.testing.expectEqualStrings("Pt", r.name); // :::class dropped
    try std.testing.expect(parsePoint("no brackets") == null);
    try std.testing.expect(parsePoint("Label: [0.5]") == null); // needs two coordinates
}
