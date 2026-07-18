//! Syntax Ref: https://mermaid.ai/open-source/syntax/pie.html
//!
//! Horizontal proportional bars with percentages.

const std = @import("std");
const width = @import("../markdown/width.zig");
const text = @import("text.zig");

const ws = text.ws;
const appendSpaces = text.appendSpaces;

pub fn render(arena: std.mem.Allocator, src: []const u8, ascii: bool) ![]const u8 {
    const Slice = struct { label: []const u8, value: f64 };
    var slices: std.ArrayList(Slice) = .empty;
    defer slices.deinit(arena);
    var title: []const u8 = "";
    var total: f64 = 0;
    var max_label: usize = 0;

    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, ws);
        if (t.len == 0 or std.mem.startsWith(u8, t, "%%")) continue;
        if (std.mem.startsWith(u8, t, "pie")) {
            var rest = std.mem.trim(u8, t[3..], ws);
            rest = std.mem.trim(u8, trimPrefix(rest, "showData"), ws);
            if (std.mem.startsWith(u8, rest, "title")) title = std.mem.trim(u8, rest[5..], ws);
            continue;
        }
        if (parsePieSlice(t)) |s| {
            try slices.append(arena, .{ .label = s.label, .value = s.value });
            total += s.value;
            max_label = @max(max_label, width.displayWidth(s.label));
        }
    }
    if (slices.items.len == 0) return error.NoSlices;
    if (total == 0) total = 1;

    const bar_width: usize = 24;
    const bar_char: []const u8 = if (ascii) "#" else "\u{2588}"; // █

    var out: std.ArrayList(u8) = .empty;
    if (title.len > 0) {
        try out.appendSlice(arena, title);
        try out.appendSlice(arena, "\n\n");
    }
    for (slices.items) |s| {
        const pct = s.value / total * 100;
        const n: usize = @intFromFloat(pct / 100 * @as(f64, bar_width) + 0.5);
        try out.appendSlice(arena, s.label);
        try appendSpaces(&out, arena, max_label - width.displayWidth(s.label) + 2);
        try text.appendBar(&out, arena, bar_char, n, bar_width);
        const tail = try std.fmt.allocPrint(arena, "  {d:>5.1}%  ({s})\n", .{ pct, trimFloat(arena, s.value) });
        try out.appendSlice(arena, tail);
    }
    return std.mem.trimEnd(u8, out.items, "\n");
}

const PieSlice = struct { label: []const u8, value: f64 };

fn parsePieSlice(t: []const u8) ?PieSlice {
    if (t.len == 0 or t[0] != '"') return null;
    const close = std.mem.indexOfScalarPos(u8, t, 1, '"') orelse return null;
    const label = t[1..close];
    var rest = std.mem.trim(u8, t[close + 1 ..], ws);
    if (rest.len == 0 or rest[0] != ':') return null;
    rest = std.mem.trim(u8, rest[1..], ws);
    const value = std.fmt.parseFloat(f64, rest) catch return null;
    return .{ .label = label, .value = value };
}

fn trimFloat(arena: std.mem.Allocator, v: f64) []const u8 {
    return text.fmtNum(arena, v, "{d}");
}

fn trimPrefix(s: []const u8, prefix: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, s, prefix)) s[prefix.len..] else s;
}

test "parsePieSlice reads a quoted label and its value" {
    const s = parsePieSlice("\"Dogs\" : 42.5").?;
    try std.testing.expectEqualStrings("Dogs", s.label);
    try std.testing.expectEqual(@as(f64, 42.5), s.value);
    try std.testing.expect(parsePieSlice("Dogs : 42") == null); // label must be quoted
    try std.testing.expect(parsePieSlice("\"Dogs\" 42") == null); // needs a colon
}

test "trimFloat drops the decimal for whole values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("3", trimFloat(arena.allocator(), 3.0));
    try std.testing.expectEqualStrings("2.5", trimFloat(arena.allocator(), 2.5));
}

test "trimPrefix strips only a matching prefix" {
    try std.testing.expectEqualStrings(" x", trimPrefix("showData x", "showData"));
    try std.testing.expectEqualStrings("title", trimPrefix("title", "showData"));
}
