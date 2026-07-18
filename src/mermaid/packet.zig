//! Syntax Ref: https://mermaid.ai/open-source/syntax/packet.html
//!
//! Mermaid packet / packet-beta as a bit-field grid, 32 bits per row.
//!
//! Boxes go on the connection layer so adjacent walls merge into junctions. A
//! field spanning a 32-bit boundary is split across rows.

const std = @import("std");
const Canvas = @import("canvas.zig").Canvas;
const putCentered = @import("canvas.zig").putCentered;
const width = @import("../markdown/width.zig");
const text = @import("text.zig");

const ws = text.ws;
const bits_per_row: usize = 32;
const cell_w: usize = 2; // columns per bit
const row_h: usize = 4; // ruler(1) + box(3)

const Field = struct { start: usize, end: usize, label: []const u8 };

pub fn render(arena: std.mem.Allocator, src: []const u8, ascii: bool) ![]const u8 {
    var title: []const u8 = "";
    var fields: std.ArrayList(Field) = .empty;
    var cursor: usize = 0; // next bit for the relative `+count` form

    var it = text.BodyLines.init(src); // skips the header line, blanks, %%
    while (it.next()) |ln| {
        const t = ln.text;
        if (std.mem.startsWith(u8, t, "title ")) {
            title = std.mem.trim(u8, t[6..], ws);
            continue;
        }
        if (parseField(t, cursor)) |f| {
            try fields.append(arena, f);
            cursor = f.end + 1;
        }
    }
    if (fields.items.len == 0) return error.Empty;

    var max_bit: usize = 0;
    for (fields.items) |f| max_bit = @max(max_bit, f.end);
    const n_rows = max_bit / bits_per_row + 1;

    const canvas_w = bits_per_row * cell_w + 1;
    const canvas_h = n_rows * row_h;
    var c = try Canvas.init(arena, canvas_w, canvas_h);

    for (fields.items) |f| {
        var rr = f.start / bits_per_row;
        const last_row = f.end / bits_per_row;
        while (rr <= last_row) : (rr += 1) {
            const row_base = rr * bits_per_row;
            const rs = @max(f.start, row_base); // first bit of this part
            const re = @min(f.end, row_base + bits_per_row - 1); // last bit
            const a = rs - row_base; // within-row offset
            const b = re - row_base;
            const x0 = a * cell_w;
            const x1 = (b + 1) * cell_w;
            const ruler_y = rr * row_h;
            const top = ruler_y + 1;
            const bot = ruler_y + 3;
            // Box on the connection layer so shared walls become tees.
            c.lineH(x0, x1, top);
            c.lineH(x0, x1, bot);
            c.lineV(top, bot, x0);
            c.lineV(top, bot, x1);
            // Bit index on the ruler row, at the field's left edge.
            var buf: [8]u8 = undefined;
            const num = std.fmt.bufPrint(&buf, "{d}", .{rs}) catch "";
            c.putStr(x0, ruler_y, num);
            // Label centred in the box interior.
            const inner = if (x1 > x0 + 1) x1 - x0 - 1 else 0;
            putCentered(c, x0 + 1, inner, top + 1, clip(f.label, inner));
        }
    }

    const body = try c.toString(ascii);
    if (title.len > 0) return std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ title, body });
    return body;
}

/// `start-end: "label"`, `start: "label"` or `+count: "label"`. `cursor` is the next
/// free bit, for the relative form. Null on non-field lines.
fn parseField(t: []const u8, cursor: usize) ?Field {
    const colon = std.mem.indexOfScalar(u8, t, ':') orelse return null;
    const spec = std.mem.trim(u8, t[0..colon], ws);
    if (spec.len == 0) return null;
    var label = std.mem.trim(u8, t[colon + 1 ..], ws);
    label = std.mem.trim(u8, label, "\"");

    if (spec[0] == '+') {
        const count = std.fmt.parseInt(usize, std.mem.trim(u8, spec[1..], ws), 10) catch return null;
        if (count == 0) return null;
        return .{ .start = cursor, .end = cursor + count - 1, .label = label };
    }
    if (std.mem.indexOfScalar(u8, spec, '-')) |dash| {
        const s = std.fmt.parseInt(usize, std.mem.trim(u8, spec[0..dash], ws), 10) catch return null;
        const e = std.fmt.parseInt(usize, std.mem.trim(u8, spec[dash + 1 ..], ws), 10) catch return null;
        if (e < s) return null;
        return .{ .start = s, .end = e, .label = label };
    }
    const s = std.fmt.parseInt(usize, spec, 10) catch return null;
    return .{ .start = s, .end = s, .label = label };
}

const clip = text.clip;

test "packet renders field labels, bit indices and box junctions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "packet-beta\n" ++
        "title UDP Packet\n" ++
        "0-15: \"Source Port\"\n" ++
        "16-31: \"Destination Port\"\n" ++
        "32-47: \"Length\"\n" ++
        "48-63: \"Checksum\"\n";
    const art = try render(arena.allocator(), src, false);
    for ([_][]const u8{ "UDP Packet", "Source Port", "Destination Port", "Length", "Checksum", "16", "48" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, art, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{252C}") != null); // ┬ shared wall between adjacent fields
}

test "packet supports single-bit and relative +count fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "packet-beta\n" ++
        "0: \"X\"\n" ++ // single bit (label clips to one column)
        "+4: \"Data\"\n"; // relative: 4 bits → 1..4
    const art = try render(arena.allocator(), src, true);
    try std.testing.expect(std.mem.indexOf(u8, art, "X") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "Data") != null); // relative field placed and wide enough
    try std.testing.expect(std.mem.indexOf(u8, art, "+") != null); // ascii box corners
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{252C}") == null); // no unicode glyphs in ascii ┬
}
