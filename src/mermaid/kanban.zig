//! Syntax Ref: https://mermaid.ai/open-source/syntax/kanban.html
//!
//! Mermaid kanban as side-by-side columns of cards.
//!
//! Two indentation levels: top-indent items are columns, deeper ones are cards.

const std = @import("std");
const Canvas = @import("canvas.zig").Canvas;
const BoxGlyphs = @import("canvas.zig").BoxGlyphs;
const drawBox = @import("canvas.zig").drawBox;
const width = @import("../markdown/width.zig");
const text = @import("text.zig");

const ws = text.ws;

const card_w_max: usize = 18; // inner card text cap (display cols)
const gap: usize = 1; // blank columns between lanes

const Column = struct {
    title: []const u8,
    cards: std.ArrayList([]const u8) = .empty,
};

pub fn render(arena: std.mem.Allocator, src: []const u8, ascii_mode: bool) ![]const u8 {
    var cols: std.ArrayList(Column) = .empty;
    var col_indent: ?usize = null;

    var it = text.BodyLines.init(src); // skips the header line, blanks, %%
    while (it.next()) |ln| {
        const t = ln.text;
        const indent = leadingSpaces(ln.raw);
        const card = extractCard(t);
        if (card.len == 0) continue;
        if (col_indent == null) col_indent = indent;
        if (indent <= col_indent.?) {
            col_indent = indent; // a column header
            try cols.append(arena, .{ .title = card });
        } else if (cols.items.len > 0) {
            try cols.items[cols.items.len - 1].cards.append(arena, card);
        }
    }
    if (cols.items.len == 0) return error.Empty;

    // Geometry: per-column inner card width, box width and height.
    var total_w: usize = 0;
    var max_h: usize = 0;
    const cw = try arena.alloc(usize, cols.items.len); // inner card text width
    const colw = try arena.alloc(usize, cols.items.len); // column outer width
    for (cols.items, 0..) |col, i| {
        var w: usize = width.displayWidth(col.title);
        for (col.cards.items) |card| w = @max(w, @min(width.displayWidth(card), card_w_max));
        cw[i] = @max(w, 3);
        colw[i] = cw[i] + 4; // borders + nested card box
        total_w += colw[i];
        const h = colHeight(col.cards.items.len);
        max_h = @max(max_h, h);
    }
    total_w += gap * (cols.items.len - 1);

    var c = try Canvas.init(arena, total_w, max_h);
    const bx = if (ascii_mode) BoxGlyphs.ascii else BoxGlyphs.unicode;
    var x: usize = 0;
    for (cols.items, 0..) |col, i| {
        const h = colHeight(col.cards.items.len);
        drawBox(c, bx, x, 0, colw[i], h);
        c.putStr(x + 2, 0, clip(col.title, colw[i] - 3)); // title in top border
        for (col.cards.items, 0..) |card, k| {
            const cardy = 2 + 4 * k;
            drawBox(c, bx, x + 1, cardy, cw[i] + 2, 3);
            c.putStr(x + 2, cardy + 1, clip(card, cw[i]));
        }
        x += colw[i] + gap;
    }
    return c.toString(ascii_mode);
}

fn colHeight(ncards: usize) usize {
    return if (ncards == 0) 3 else 4 * ncards + 3;
}

/// Unwraps `id[Text]` / `[Text]` / plain text, dropping a trailing `@{ ... }`
/// metadata suffix.
fn extractCard(s: []const u8) []const u8 {
    var t = s;
    if (std.mem.indexOf(u8, t, "@{")) |m| t = std.mem.trimEnd(u8, t[0..m], ws);
    if (std.mem.indexOfScalar(u8, t, '[')) |o| {
        if (std.mem.lastIndexOfScalar(u8, t, ']')) |cl| {
            if (cl > o) return std.mem.trim(u8, t[o + 1 .. cl], ws);
        }
    }
    return std.mem.trim(u8, t, ws);
}

const leadingSpaces = text.leadingSpaces;

const clip = text.clip;

test "kanban renders columns side by side with card boxes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "kanban\n" ++
        "  Todo\n" ++
        "    [Create docs]\n" ++
        "    docs[Write blog post]\n" ++
        "  id1[In progress]\n" ++
        "    id6[Build renderer]\n" ++
        "  Done\n" ++
        "    id5[define getData]\n";
    const art = try render(arena.allocator(), src, false);
    for ([_][]const u8{ "Todo", "In progress", "Done", "Create docs", "Build renderer", "define getData" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, art, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{250C}") != null); // a box corner ┌
}

test "kanban ascii mode and @{} metadata stripping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "kanban\n" ++
        "  Todo\n" ++
        "    id1[Design grammar]@{ assigned: 'knsv' }\n";
    const art = try render(arena.allocator(), src, true);
    try std.testing.expect(std.mem.indexOf(u8, art, "Design grammar") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "knsv") == null); // metadata dropped
    try std.testing.expect(std.mem.indexOf(u8, art, "+") != null); // ascii corner
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{250C}") == null); // ┌
}

test "extractCard unwraps [label], drops @{...} metadata, else trims" {
    try std.testing.expectEqualStrings("In progress", extractCard("id1[In progress]"));
    try std.testing.expectEqualStrings("Create docs", extractCard("[Create docs]"));
    try std.testing.expectEqualStrings("Todo", extractCard("Todo"));
    // A trailing @{ ... } metadata block is stripped before unwrapping the label.
    try std.testing.expectEqualStrings("Build renderer", extractCard("id6[Build renderer]@{ assigned: 'x' }"));
}
