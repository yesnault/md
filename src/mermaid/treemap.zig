//! Syntax Ref: https://mermaid.ai/open-source/syntax/treemap.html
//!
//! Mermaid treemap: an indented tree (indentation-defined, like mindmap) where
//! every row carries a bar scaled to the grand total. Internal nodes inherit the
//! sum of their descendants.

const std = @import("std");
const width = @import("../markdown/width.zig");
const text = @import("text.zig");

const ws = text.ws;
const bar_cells: usize = 16; // full-scale bar width

const Node = struct {
    text: []const u8,
    value: ?f64 = null,
    children: std.ArrayList(usize) = .empty,
};

const Glyphs = struct { tee: []const u8, last: []const u8, bar: []const u8, gap: []const u8, fill: []const u8 };
const unicode = Glyphs{ .tee = "\u{251C}\u{2500} ", .last = "\u{2514}\u{2500} ", .bar = "\u{2502}  ", .gap = "   ", .fill = "\u{2588}" }; // ├─ └─ │ █
const ascii = Glyphs{ .tee = "|- ", .last = "`- ", .bar = "|  ", .gap = "   ", .fill = "#" };

pub fn render(arena: std.mem.Allocator, src: []const u8, ascii_mode: bool) ![]const u8 {
    var nodes: std.ArrayList(Node) = .empty;
    var roots: std.ArrayList(usize) = .empty;
    var title: []const u8 = "";

    const Frame = struct { idx: usize, indent: usize };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(arena);

    var it = text.BodyLines.init(src); // skips the header line, blanks, %%
    while (it.next()) |ln| {
        const trimmed = ln.text;
        if (std.mem.startsWith(u8, trimmed, "title ")) {
            title = std.mem.trim(u8, trimmed[6..], ws);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "classDef ")) continue;
        const parsed = parseLine(trimmed);
        if (parsed.text.len == 0) continue;
        const indent = leadingSpaces(ln.raw);

        const idx = nodes.items.len;
        try nodes.append(arena, .{ .text = parsed.text, .value = parsed.value });
        while (stack.items.len > 0 and stack.items[stack.items.len - 1].indent >= indent) {
            _ = stack.pop();
        }
        if (stack.items.len == 0) {
            try roots.append(arena, idx);
        } else {
            const parent = stack.items[stack.items.len - 1].idx;
            try nodes.items[parent].children.append(arena, idx);
        }
        try stack.append(arena, .{ .idx = idx, .indent = indent });
    }
    if (nodes.items.len == 0) return error.Empty;

    var total: f64 = 0;
    for (roots.items) |r| total += resolve(nodes.items, r);
    if (total <= 0) return error.Empty;

    const g = if (ascii_mode) ascii else unicode;

    // Pass 1: build the tree-text of each row and find the widest, so the bar
    // column lines up regardless of nesting depth.
    var rows: std.ArrayList(Row) = .empty;
    for (roots.items) |r| try collect(arena, &rows, nodes.items, r, "", g, true);
    var maxw: usize = 0;
    for (rows.items) |row| maxw = @max(maxw, width.displayWidth(row.text));

    var out: std.ArrayList(u8) = .empty;
    if (title.len > 0) {
        try out.appendSlice(arena, title);
        try out.appendSlice(arena, "\n\n");
    }
    for (rows.items) |row| {
        try out.appendSlice(arena, row.text);
        try text.appendSpaces(&out, arena, maxw - width.displayWidth(row.text) + 1);
        const frac = row.value / total;
        var filled = @as(usize, @intFromFloat(@round(frac * @as(f64, bar_cells))));
        if (filled == 0 and row.value > 0) filled = 1;
        try text.appendBar(&out, arena, g.fill, filled, bar_cells);
        try out.append(arena, ' ');
        try out.appendSlice(arena, fmtNum(arena, row.value));
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, " ({d:.0}%)", .{frac * 100}));
        try out.append(arena, '\n');
    }
    return std.mem.trimEnd(u8, out.items, "\n");
}

const Row = struct { text: []const u8, value: f64 };

/// Internal nodes take the sum of their children.
fn resolve(nodes: []Node, idx: usize) f64 {
    const kids = nodes[idx].children.items;
    if (kids.len == 0) return nodes[idx].value orelse 0;
    var sum: f64 = 0;
    for (kids) |k| sum += resolve(nodes, k);
    nodes[idx].value = sum;
    return sum;
}

/// One Row per node, depth-first, each holding the rendered tree prefix + connector
/// + label, so width can be measured before the bar is drawn.
fn collect(arena: std.mem.Allocator, rows: *std.ArrayList(Row), nodes: []const Node, idx: usize, prefix: []const u8, g: Glyphs, is_root: bool) !void {
    if (is_root) {
        try rows.append(arena, .{ .text = nodes[idx].text, .value = nodes[idx].value orelse 0 });
    }
    const kids = nodes[idx].children.items;
    for (kids, 0..) |kid, i| {
        const last = i == kids.len - 1;
        const label = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ prefix, if (last) g.last else g.tee, nodes[kid].text });
        try rows.append(arena, .{ .text = label, .value = nodes[kid].value orelse 0 });
        const child_prefix = try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, if (last) g.gap else g.bar });
        try collect(arena, rows, nodes, kid, child_prefix, g, false);
    }
}

const Parsed = struct { text: []const u8, value: ?f64 };

/// Label and optional `: value` from a node line. Labels may be quoted. A trailing
/// `:::class` decoration is dropped.
fn parseLine(s: []const u8) Parsed {
    var t = s;
    if (std.mem.indexOf(u8, t, ":::")) |p| t = std.mem.trimEnd(u8, t[0..p], ws);
    if (t.len == 0) return .{ .text = "", .value = null };
    if (t[0] == '"') {
        const close = std.mem.indexOfScalarPos(u8, t, 1, '"') orelse return .{ .text = std.mem.trim(u8, t, "\""), .value = null };
        const label = t[1..close];
        const rest = std.mem.trim(u8, t[close + 1 ..], ws);
        return .{ .text = label, .value = parseValueAfterColon(rest) };
    }
    // Unquoted: split on the last colon if the tail is numeric.
    if (std.mem.lastIndexOfScalar(u8, t, ':')) |c| {
        if (parseFloat(std.mem.trim(u8, t[c + 1 ..], ws))) |v| {
            return .{ .text = std.mem.trim(u8, t[0..c], ws), .value = v };
        }
    }
    return .{ .text = t, .value = null };
}

fn parseValueAfterColon(rest: []const u8) ?f64 {
    if (rest.len == 0 or rest[0] != ':') return null;
    return parseFloat(std.mem.trim(u8, rest[1..], ws));
}

fn parseFloat(s: []const u8) ?f64 {
    if (s.len == 0) return null;
    return std.fmt.parseFloat(f64, s) catch null;
}

fn fmtNum(arena: std.mem.Allocator, v: f64) []const u8 {
    return text.fmtNum(arena, v, "{d:.2}");
}

const leadingSpaces = text.leadingSpaces;

test "treemap aggregates sections and draws bars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "treemap-beta\n" ++
        "title Storage\n" ++
        "\"Section 1\"\n" ++
        "    \"Leaf 1.1\": 12\n" ++
        "    \"Leaf 1.2\": 8\n" ++
        "\"Section 2\"\n" ++
        "    \"Leaf 2.1\": 20\n";
    const art = try render(arena.allocator(), src, false);
    for ([_][]const u8{ "Storage", "Section 1", "Leaf 1.1", "Leaf 2.1" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, art, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{2588}") != null); // bar fill █
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{251C}\u{2500}") != null); // tee ├─
    try std.testing.expect(std.mem.indexOf(u8, art, "20 (50%)") != null); // Section 1 = Section 2 = 20 of 40
    try std.testing.expect(std.mem.indexOf(u8, art, "12 (30%)") != null);
}

test "treemap ascii mode and unquoted labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "treemap\n" ++
        "Root\n" ++
        "  A: 3\n" ++
        "  B: 1\n";
    const art = try render(arena.allocator(), src, true);
    try std.testing.expect(std.mem.indexOf(u8, art, "#") != null); // ascii bar
    try std.testing.expect(std.mem.indexOf(u8, art, "`- B") != null); // ascii last connector
    try std.testing.expect(std.mem.indexOf(u8, art, "|- A") != null); // ascii tee
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{2588}") == null); // no unicode fill █
    try std.testing.expect(std.mem.indexOf(u8, art, "3 (75%)") != null);
}

test "treemap parseFloat parses a float, else null" {
    try std.testing.expectEqual(@as(?f64, 42), parseFloat("42"));
    try std.testing.expectEqual(@as(?f64, 3.5), parseFloat("3.5"));
    try std.testing.expectEqual(@as(?f64, null), parseFloat(""));
    try std.testing.expectEqual(@as(?f64, null), parseFloat("abc"));
}

test "treemap parseValueAfterColon needs a leading colon" {
    try std.testing.expectEqual(@as(?f64, 42), parseValueAfterColon(": 42"));
    try std.testing.expectEqual(@as(?f64, null), parseValueAfterColon("42"));
    try std.testing.expectEqual(@as(?f64, null), parseValueAfterColon(""));
}

test "treemap parseLine reads quoted labels, colon values and :::class" {
    const a = parseLine("\"Apples\": 30");
    try std.testing.expectEqualStrings("Apples", a.text);
    try std.testing.expectEqual(@as(?f64, 30), a.value);
    const b = parseLine("\"Fruits\"");
    try std.testing.expectEqualStrings("Fruits", b.text);
    try std.testing.expectEqual(@as(?f64, null), b.value);
    // Unquoted: split on the last colon only when the tail is numeric.
    const c = parseLine("Leaf: 5");
    try std.testing.expectEqualStrings("Leaf", c.text);
    try std.testing.expectEqual(@as(?f64, 5), c.value);
    const d = parseLine("Section");
    try std.testing.expectEqualStrings("Section", d.text);
    try std.testing.expectEqual(@as(?f64, null), d.value);
    // A ::: class decoration is dropped.
    const e = parseLine("Node:::hot");
    try std.testing.expectEqualStrings("Node", e.text);
    try std.testing.expectEqual(@as(?f64, null), e.value);
}
