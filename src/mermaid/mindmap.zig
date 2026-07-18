//! Syntax Ref: https://mermaid.ai/open-source/syntax/mindmap.html
//!
//! Mermaid mindmap as an indented tree, rendered like the `tree` command.
//! Hierarchy comes from leading indentation. Node shapes and `::icon()` /
//! `:::class` decorations are stripped to their inner text.

const std = @import("std");
const text = @import("text.zig");

const ws = text.ws;

const Node = struct {
    text: []const u8,
    children: std.ArrayList(usize) = .empty,
};

const Glyphs = struct { tee: []const u8, last: []const u8, bar: []const u8, gap: []const u8 };
const unicode = Glyphs{ .tee = "\u{251C}\u{2500} ", .last = "\u{2514}\u{2500} ", .bar = "\u{2502}  ", .gap = "   " }; // ├─ └─ │
const ascii = Glyphs{ .tee = "|- ", .last = "`- ", .bar = "|  ", .gap = "   " };

pub fn render(arena: std.mem.Allocator, src: []const u8, ascii_mode: bool) ![]const u8 {
    var nodes: std.ArrayList(Node) = .empty;
    var roots: std.ArrayList(usize) = .empty;

    const Frame = struct { idx: usize, indent: usize };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(arena);

    var it = text.BodyLines.init(src); // skips the header line, blanks, %%
    while (it.next()) |ln| {
        const trimmed = ln.text;
        const label = extractText(trimmed);
        if (label.len == 0) continue;
        const indent = leadingSpaces(ln.raw);

        const idx = nodes.items.len;
        try nodes.append(arena, .{ .text = label });
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

    const g = if (ascii_mode) ascii else unicode;
    var out: std.ArrayList(u8) = .empty;
    for (roots.items) |r| {
        try out.appendSlice(arena, nodes.items[r].text);
        try out.append(arena, '\n');
        try printChildren(arena, &out, nodes.items, r, "", g);
    }
    return std.mem.trimEnd(u8, out.items, "\n");
}

fn printChildren(arena: std.mem.Allocator, out: *std.ArrayList(u8), nodes: []const Node, parent: usize, prefix: []const u8, g: Glyphs) !void {
    const kids = nodes[parent].children.items;
    for (kids, 0..) |kid, i| {
        const last = i == kids.len - 1;
        try out.appendSlice(arena, prefix);
        try out.appendSlice(arena, if (last) g.last else g.tee);
        try out.appendSlice(arena, nodes[kid].text);
        try out.append(arena, '\n');
        const child_prefix = try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, if (last) g.gap else g.bar });
        try printChildren(arena, out, nodes, kid, child_prefix, g);
    }
}

const leadingSpaces = text.leadingSpaces;

/// Drops a trailing `::icon`/`:::class` decoration, then unwraps a shape wrapper.
fn extractText(s: []const u8) []const u8 {
    var t = s;
    if (std.mem.indexOf(u8, t, "::")) |p| t = std.mem.trimEnd(u8, t[0..p], ws);
    if (t.len == 0) return t;
    // Cloud shape: )text(
    if (t[0] == ')') return std.mem.trim(u8, t, ")(");
    const open = std.mem.indexOfAny(u8, t, "([{") orelse return t;
    const close = std.mem.lastIndexOfAny(u8, t, ")]}") orelse return t;
    if (close <= open) return t;
    const inner = std.mem.trim(u8, t[open .. close + 1], "([{)]}");
    return std.mem.trim(u8, inner, "\"");
}

test "mindmap builds an indented tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "mindmap\n" ++
        "  root((mindmap))\n" ++
        "    Origins\n" ++
        "      Long history\n" ++
        "    Research\n";
    const art = try render(arena.allocator(), src, false);
    try std.testing.expect(std.mem.indexOf(u8, art, "mindmap") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "Origins") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "Long history") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{251C}\u{2500}") != null); // tee connector ├─
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{2514}\u{2500}") != null); // last connector └─
}

test "mindmap ascii mode uses plain connectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "mindmap\n  root\n    a\n    b\n";
    const art = try render(arena.allocator(), src, true);
    try std.testing.expect(std.mem.indexOf(u8, art, "`- b") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "|- a") != null);
}

test "extractText unwraps shapes and drops icon/class decorations" {
    // Plain label passes through unchanged.
    try std.testing.expectEqualStrings("Origins", extractText("Origins"));
    // Shape wrappers unwrap to their inner text (the leading prefix is dropped).
    try std.testing.expectEqualStrings("mindmap", extractText("root((mindmap))"));
    try std.testing.expectEqualStrings("Square topic", extractText("[Square topic]"));
    try std.testing.expectEqualStrings("Hexagon", extractText("{{Hexagon}}"));
    // Cloud shape )text( is unwrapped too.
    try std.testing.expectEqualStrings("Cloud", extractText(")Cloud("));
    // Quotes inside a shape are stripped.
    try std.testing.expectEqualStrings("Quoted", extractText("[\"Quoted\"]"));
    // Trailing ::icon()/:::class decorations are removed.
    try std.testing.expectEqualStrings("Research", extractText("Research ::icon(fa fa-book)"));
    try std.testing.expectEqualStrings("Node", extractText("Node:::urgent"));
    // Decoration and shape combine: decoration removed first, then shape unwrapped.
    try std.testing.expectEqualStrings("Book", extractText("[Book]::icon(fa fa-book)"));
}
