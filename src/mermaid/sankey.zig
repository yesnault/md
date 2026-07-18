//! Syntax Ref: https://mermaid.ai/open-source/syntax/sankey.html
//!
//! A faithful 2D sankey is poor at terminal resolution, so flows are grouped by
//! source with a value-proportional bar each. Input is CSV: `source,target,value`.

const std = @import("std");
const width = @import("../markdown/width.zig");
const text = @import("text.zig");

const ws = text.ws;
const bar_width: usize = 24;

const Flow = struct { src: []const u8, tgt: []const u8, value: f64 };

pub fn render(arena: std.mem.Allocator, src: []const u8, ascii: bool) ![]const u8 {
    var flows: std.ArrayList(Flow) = .empty;
    var max_v: f64 = 0;
    var max_src: usize = 0;
    var max_tgt: usize = 0;

    var it = text.BodyLines.init(src); // skips the header line, blanks, %%
    while (it.next()) |ln| {
        const t = ln.text;
        const fields = try parseCsvRow(arena, t);
        if (fields.len < 3) continue;
        const v = std.fmt.parseFloat(f64, std.mem.trim(u8, fields[2], ws)) catch continue;
        const f = Flow{ .src = fields[0], .tgt = fields[1], .value = v };
        try flows.append(arena, f);
        max_v = @max(max_v, v);
        max_src = @max(max_src, width.displayWidth(f.src));
        max_tgt = @max(max_tgt, width.displayWidth(f.tgt));
    }
    if (flows.items.len == 0) return error.Empty;
    if (max_v == 0) max_v = 1;

    const block: []const u8 = if (ascii) "#" else "\u{2588}"; // █
    const arrow: []const u8 = if (ascii) "->" else "\u{2192}"; // →

    var out: std.ArrayList(u8) = .empty;
    var last_src: []const u8 = "\x00";
    for (flows.items) |f| {
        // Print the source only once per group for readability.
        const same = std.mem.eql(u8, f.src, last_src);
        if (same) {
            try appendSpaces(&out, arena, max_src);
        } else {
            try out.appendSlice(arena, f.src);
            try appendSpaces(&out, arena, max_src - width.displayWidth(f.src));
            last_src = f.src;
        }
        try out.appendSlice(arena, "  ");
        try out.appendSlice(arena, arrow);
        try out.append(arena, ' ');
        try out.appendSlice(arena, f.tgt);
        try appendSpaces(&out, arena, max_tgt - width.displayWidth(f.tgt) + 2);
        const n: usize = @intFromFloat(f.value / max_v * @as(f64, bar_width) + 0.5);
        try text.appendBar(&out, arena, block, n, bar_width);
        try appendSpaces(&out, arena, 2);
        try out.appendSlice(arena, fmtNum(arena, f.value));
        try out.append(arena, '\n');
    }

    // Per-node totals (out = leaving, in = entering), in first-seen order.
    var names: std.ArrayList([]const u8) = .empty;
    var outs: std.StringHashMap(f64) = .init(arena);
    var ins: std.StringHashMap(f64) = .init(arena);
    var max_name: usize = 0;
    for (flows.items) |f| {
        try bump(arena, &names, &outs, f.src, f.value, &max_name);
        try bump(arena, &names, &ins, f.tgt, f.value, &max_name);
    }
    try out.append(arena, '\n');
    try out.appendSlice(arena, "Totals (out / in)\n");
    for (names.items) |name| {
        try out.appendSlice(arena, "  ");
        try out.appendSlice(arena, name);
        try appendSpaces(&out, arena, max_name - width.displayWidth(name) + 2);
        const o = outs.get(name) orelse 0;
        const i = ins.get(name) orelse 0;
        const line = try std.fmt.allocPrint(arena, "out {s}  in {s}\n", .{ fmtNum(arena, o), fmtNum(arena, i) });
        try out.appendSlice(arena, line);
    }
    return std.mem.trimEnd(u8, out.items, "\n");
}

fn bump(
    arena: std.mem.Allocator,
    names: *std.ArrayList([]const u8),
    map: *std.StringHashMap(f64),
    name: []const u8,
    v: f64,
    max_name: *usize,
) !void {
    const gop = try map.getOrPut(name);
    if (!gop.found_existing) {
        gop.value_ptr.* = 0;
        // Register only when neither map has seen it yet.
        var seen = false;
        for (names.items) |x| if (std.mem.eql(u8, x, name)) {
            seen = true;
            break;
        };
        if (!seen) {
            try names.append(arena, name);
            max_name.* = @max(max_name.*, width.displayWidth(name));
        }
    }
    gop.value_ptr.* += v;
}

/// One CSV line, honouring `"..."` quoting and `""` escapes.
fn parseCsvRow(arena: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var fields: std.ArrayList([]const u8) = .empty;
    var buf: std.ArrayList(u8) = .empty;
    var in_q = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (in_q) {
            if (c == '"') {
                if (i + 1 < line.len and line[i + 1] == '"') {
                    try buf.append(arena, '"');
                    i += 1;
                } else in_q = false;
            } else try buf.append(arena, c);
        } else if (c == '"') {
            in_q = true;
        } else if (c == ',') {
            try fields.append(arena, try buf.toOwnedSlice(arena));
            buf = .empty;
        } else try buf.append(arena, c);
    }
    try fields.append(arena, try buf.toOwnedSlice(arena));
    for (fields.items) |*f| f.* = std.mem.trim(u8, f.*, ws);
    return fields.items;
}

fn fmtNum(arena: std.mem.Allocator, v: f64) []const u8 {
    return text.fmtNum(arena, v, "{d}");
}

const appendSpaces = text.appendSpaces;

test "sankey lists flows with bars proportional to value and node totals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "sankey-beta\n" ++
        "A,B,100\n" ++
        "A,C,10\n";
    const art = try render(arena.allocator(), src, true);
    for ([_][]const u8{ "A", "B", "C", "100", "Totals", "out 110", "in 100" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, art, needle) != null);
    }
    // Bar length is proportional to value: the A→B flow has more bar than A→C.
    var lines = std.mem.splitScalar(u8, art, '\n');
    var b_bars: usize = 0;
    var c_bars: usize = 0;
    while (lines.next()) |ln| {
        if (std.mem.indexOf(u8, ln, "->") == null) continue; // flow rows only (skip totals)
        if (std.mem.indexOf(u8, ln, "B") != null) b_bars = std.mem.count(u8, ln, "#");
        if (std.mem.indexOf(u8, ln, "C") != null) c_bars = std.mem.count(u8, ln, "#");
    }
    try std.testing.expect(b_bars > c_bars);
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{2588}") == null); // ascii uses '#' █
}

test "sankey handles quoted fields with commas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "sankey-beta\n" ++
        "\"Agricultural, waste\",Bio-conversion,124.729\n";
    const art = try render(arena.allocator(), src, false);
    try std.testing.expect(std.mem.indexOf(u8, art, "Agricultural, waste") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "Bio-conversion") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "124.729") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{2588}") != null); // unicode bar █
}
