//! Syntax Ref: https://mermaid.ai/open-source/syntax/block.html
//!
//! Blocks pack left to right and wrap when a row fills. Nested `block:id ... end`
//! groups lay out recursively inside a titled box. Shape wrappers parse but all
//! render as rectangles. Spans wider than `columns`, deep nesting and crossing
//! arrows are not specially handled.

const std = @import("std");
const Canvas = @import("canvas.zig").Canvas;
const width = @import("../markdown/width.zig");
const text = @import("text.zig");

const ws = text.ws;
const gap_x: usize = 3;
const gap_y: usize = 1;
const margin: usize = 1;
const box_h: usize = 3;

const Leaf = struct { id: []const u8, label: []const u8, span: usize };
const Group = struct { id: []const u8, label: []const u8, span: usize, inner: Container };
const Item = union(enum) { leaf: Leaf, group: *Group, spacer: usize };
const Container = struct { columns: usize = 0, items: std.ArrayList(Item) = .empty };

const Arrow = struct { from: []const u8, to: []const u8, label: []const u8 };
const Rect = struct { x: usize, y: usize, w: usize, h: usize };

pub fn render(arena: std.mem.Allocator, src: []const u8, ascii: bool) ![]const u8 {
    var root = Container{};
    var stack: std.ArrayList(*Container) = .empty;
    try stack.append(arena, &root);
    var arrows: std.ArrayList(Arrow) = .empty;

    var it = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, ws);
        if (first) {
            first = false;
            continue; // skip "block" / "block-beta"
        }
        if (t.len == 0 or std.mem.startsWith(u8, t, "%%")) continue;
        const cur = stack.items[stack.items.len - 1];

        if (std.mem.eql(u8, t, "end")) {
            if (stack.items.len > 1) _ = stack.pop();
            continue;
        }
        if (std.mem.startsWith(u8, t, "columns ")) {
            const v = std.mem.trim(u8, t[8..], ws);
            cur.columns = std.fmt.parseInt(usize, v, 10) catch 0; // "auto" → 0
            continue;
        }
        if (std.mem.startsWith(u8, t, "block:")) {
            const g = try arena.create(Group);
            const decl = classify(std.mem.trim(u8, t[6..], ws));
            g.* = .{ .id = decl.id, .label = decl.label, .span = decl.span, .inner = .{} };
            try cur.items.append(arena, .{ .group = g });
            try stack.append(arena, &g.inner);
            continue;
        }
        if (std.mem.startsWith(u8, t, "style ") or std.mem.startsWith(u8, t, "class ") or std.mem.startsWith(u8, t, "click ")) continue;
        if (parseArrow(t)) |a| {
            try arrows.append(arena, a);
            continue;
        }
        // Otherwise: a row of blocks / spacers.
        var pos: usize = 0;
        while (nextToken(t, &pos)) |tok| {
            const decl = classify(tok);
            if (decl.id.len == 0) continue; // stray punctuation
            if (std.mem.eql(u8, decl.id, "space")) {
                try cur.items.append(arena, .{ .spacer = decl.span });
            } else {
                try cur.items.append(arena, .{ .leaf = .{ .id = decl.id, .label = decl.label, .span = decl.span } });
            }
        }
    }
    if (root.items.items.len == 0) return error.Empty;

    const placed = try place(arena, &root);
    const canvas_w = placed.w + 2 * margin;
    const canvas_h = placed.h + 2 * margin;
    var c = try Canvas.init(arena, canvas_w, canvas_h);
    var rects: std.StringHashMap(Rect) = .init(arena);
    try draw(c, ascii, placed, margin, margin, &rects);

    for (arrows.items) |a| {
        const from = rects.get(a.from) orelse continue;
        const to = rects.get(a.to) orelse continue;
        route(c, ascii, from, to, a.label);
    }
    return c.toString(ascii);
}

// --- layout ---

const Cell = struct { rx: usize, ry: usize, rw: usize, rh: usize, child: ?*Placed = null };
const Placed = struct { container: *Container, w: usize, h: usize, cell_w: usize, cells: []Cell };

/// A container's pixel size and each item's relative rectangle. Groups recurse.
/// Columns are uniform width, and a spanning item occupies `span` columns plus the
/// gaps between them.
fn place(arena: std.mem.Allocator, container: *Container) !*Placed {
    const items = container.items.items;
    const n = items.len;
    const cells = try arena.alloc(Cell, n);

    // Natural sizes (groups first, so their size feeds the column width).
    const nat_w = try arena.alloc(usize, n);
    const nat_h = try arena.alloc(usize, n);
    const span = try arena.alloc(usize, n);
    for (items, 0..) |item, i| {
        switch (item) {
            .leaf => |l| {
                nat_w[i] = @max(5, width.displayWidth(l.label) + 4);
                nat_h[i] = box_h;
                span[i] = @max(1, l.span);
            },
            .group => |g| {
                const sub = try place(arena, &g.inner);
                cells[i].child = sub;
                nat_w[i] = sub.w + 2;
                nat_h[i] = sub.h + 2;
                span[i] = @max(1, g.span);
            },
            .spacer => |s| {
                nat_w[i] = 0;
                nat_h[i] = 1;
                span[i] = @max(1, s);
            },
        }
    }

    var total_span: usize = 0;
    for (span) |s| total_span += s;
    const cols = if (container.columns > 0) container.columns else @max(1, total_span);

    // Uniform column width: the widest single-column demand (item width / span).
    var cell_w: usize = 5;
    for (0..n) |i| {
        if (items[i] == .spacer) continue;
        cell_w = @max(cell_w, ceilDiv(nat_w[i], span[i]));
    }

    // Assign grid rows/cols by packing.
    const row_of = try arena.alloc(usize, n);
    const col_of = try arena.alloc(usize, n);
    var cursor: usize = 0;
    var row: usize = 0;
    for (0..n) |i| {
        const s = @min(span[i], cols);
        if (cursor > 0 and cursor + s > cols) {
            row += 1;
            cursor = 0;
        }
        row_of[i] = row;
        col_of[i] = cursor;
        cursor += s;
    }
    const rows = row + 1;

    const row_h = try arena.alloc(usize, rows);
    @memset(row_h, 1);
    for (0..n) |i| row_h[row_of[i]] = @max(row_h[row_of[i]], nat_h[i]);
    const row_y = try arena.alloc(usize, rows);
    var y: usize = 0;
    for (0..rows) |r| {
        row_y[r] = y;
        y += row_h[r] + gap_y;
    }

    for (0..n) |i| {
        const s = @min(span[i], cols);
        const rw = s * cell_w + (s - 1) * gap_x;
        cells[i].rx = col_of[i] * (cell_w + gap_x);
        cells[i].ry = row_y[row_of[i]];
        cells[i].rw = rw;
        cells[i].rh = nat_h[i];
    }

    const placed = try arena.create(Placed);
    placed.* = .{
        .container = container,
        .w = cols * cell_w + (cols - 1) * gap_x,
        .h = if (rows > 0) row_y[rows - 1] + row_h[rows - 1] else 0,
        .cell_w = cell_w,
        .cells = cells,
    };
    return placed;
}

fn draw(c: Canvas, ascii: bool, p: *Placed, ox: usize, oy: usize, rects: *std.StringHashMap(Rect)) !void {
    const box = if (ascii) BoxGlyphs.ascii else BoxGlyphs.unicode;
    for (p.container.items.items, 0..) |item, i| {
        const cell = p.cells[i];
        const x = ox + cell.rx;
        const yy = oy + cell.ry;
        switch (item) {
            .spacer => {},
            .leaf => |l| {
                drawBox(c, box, x, yy, cell.rw, box_h);
                putCentered(c, x, cell.rw, yy + 1, l.label);
                try rects.put(l.id, .{ .x = x, .y = yy, .w = cell.rw, .h = box_h });
            },
            .group => |g| {
                drawBox(c, box, x, yy, cell.rw, cell.rh);
                if (g.label.len > 0 and cell.rw > 2) c.putStr(x + 1, yy, clip(g.label, cell.rw - 2));
                try rects.put(g.id, .{ .x = x, .y = yy, .w = cell.rw, .h = cell.rh });
                try draw(c, ascii, cell.child.?, x + 1, yy + 1, rects);
            },
        }
    }
}

// --- arrow routing ---

fn route(c: Canvas, ascii: bool, from: Rect, to: Rect, label: []const u8) void {
    const scx = from.x + from.w / 2;
    const tcx = to.x + to.w / 2;
    const scy = from.y + from.h / 2;
    const tcy = to.y + to.h / 2;

    if (to.y >= from.y + from.h) { // target below → route downward
        const ey = from.y + from.h;
        const ny = if (to.y > 0) to.y - 1 else 0;
        const my = (ey + ny) / 2;
        c.lineV(ey, my, scx);
        c.lineH(scx, tcx, my);
        c.lineV(my, ny, tcx);
        c.set(tcx, ny, if (ascii) 'v' else '\u{25BC}'); // ▼
        if (label.len > 0) c.putStr(@min(scx, tcx) + 1, my, clip(label, absDiff(scx, tcx) + 1));
    } else if (from.y >= to.y + to.h) { // target above → route upward
        const ey = if (from.y > 0) from.y - 1 else 0;
        const ny = to.y + to.h;
        const my = (ny + ey) / 2;
        c.lineV(ey, my, scx);
        c.lineH(scx, tcx, my);
        c.lineV(my, ny, tcx);
        c.set(tcx, ny, if (ascii) '^' else '\u{25B2}'); // ▲
        if (label.len > 0) c.putStr(@min(scx, tcx) + 1, my, clip(label, absDiff(scx, tcx) + 1));
    } else if (to.x >= from.x + from.w) { // target right
        const ex = from.x + from.w;
        const nx = if (to.x > 0) to.x - 1 else 0;
        const mx = (ex + nx) / 2;
        c.lineH(ex, mx, scy);
        c.lineV(scy, tcy, mx);
        c.lineH(mx, nx, tcy);
        c.set(nx, tcy, if (ascii) '>' else '\u{25B6}'); // ▶
        if (label.len > 0) c.putStr(mx, @min(scy, tcy), clip(label, to.x - mx));
    } else { // target left
        const ex = if (from.x > 0) from.x - 1 else 0;
        const nx = to.x + to.w;
        const mx = (ex + nx) / 2;
        c.lineH(ex, mx, scy);
        c.lineV(scy, tcy, mx);
        c.lineH(mx, nx, tcy);
        c.set(nx, tcy, if (ascii) '<' else '\u{25C0}'); // ◀
        if (label.len > 0) c.putStr(mx, @min(scy, tcy), clip(label, from.x - mx));
    }
}

fn absDiff(a: usize, b: usize) usize {
    return if (a > b) a - b else b - a;
}

// --- parsing ---

const Decl = struct { id: []const u8, label: []const u8, span: usize };

/// Splits `id`, an optional shape-wrapped `["label"]` and an optional `:N` span out
/// of one token. Shape wrappers all collapse to the label.
fn classify(tok: []const u8) Decl {
    var i: usize = 0;
    while (i < tok.len and isIdentChar(tok[i])) i += 1;
    const id = tok[0..i];
    var label = id;
    var rest = tok[i..];
    if (rest.len > 0 and (rest[0] == '[' or rest[0] == '(' or rest[0] == '{')) {
        // An unclosed bracket labels through to the end of the token.
        const close = matchBracket(rest) orelse rest.len;
        label = std.mem.trim(u8, rest[1..close], "()[]{}\" \t");
        if (label.len == 0) label = id;
        rest = rest[@min(close + 1, rest.len)..];
    }
    var span: usize = 1;
    if (rest.len > 0 and rest[0] == ':') {
        span = std.fmt.parseInt(usize, std.mem.trim(u8, rest[1..], ws), 10) catch 1;
    }
    return .{ .id = id, .label = label, .span = @max(1, span) };
}

/// Index (within `s`, which starts at an opener) of the matching closer, counting
/// nesting of that bracket family and ignoring quotes. Null when never closed.
fn matchBracket(s: []const u8) ?usize {
    var depth: usize = 0;
    var in_q = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (ch == '"') {
            in_q = !in_q;
        } else if (!in_q and (ch == '[' or ch == '(' or ch == '{')) {
            depth += 1;
        } else if (!in_q and (ch == ']' or ch == ')' or ch == '}')) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

/// One block token from `line` starting at `pos`, keeping a bracketed label (spaces
/// and all) and a trailing `:N` together. Null at end of line.
fn nextToken(line: []const u8, pos: *usize) ?[]const u8 {
    while (pos.* < line.len and (line[pos.*] == ' ' or line[pos.*] == '\t')) pos.* += 1;
    if (pos.* >= line.len) return null;
    const start = pos.*;
    while (pos.* < line.len and isIdentChar(line[pos.*])) pos.* += 1;
    if (pos.* < line.len and (line[pos.*] == '[' or line[pos.*] == '(' or line[pos.*] == '{')) {
        if (matchBracket(line[pos.*..])) |close| {
            pos.* += close + 1;
        } else {
            pos.* = line.len; // unclosed bracket: token runs to end of line
        }
    }
    if (pos.* < line.len and line[pos.*] == ':') {
        pos.* += 1;
        while (pos.* < line.len and (std.ascii.isDigit(line[pos.*]))) pos.* += 1;
    }
    if (pos.* == start) pos.* += 1; // guarantee progress past an unexpected char
    return line[start..pos.*];
}

const arrow_ops = [_][]const u8{ "-->", "==>", "-.->", "---" };

/// `A --> B`, `A -->|label| B` or `A -- label --> B`. Null when the line carries no
/// arrow operator.
fn parseArrow(t: []const u8) ?Arrow {
    for (arrow_ops) |op| {
        const idx = std.mem.indexOf(u8, t, op) orelse continue;
        var left = std.mem.trim(u8, t[0..idx], ws);
        var right = std.mem.trim(u8, t[idx + op.len ..], ws);
        var label: []const u8 = "";
        // `A -- label -->` : a label sits before the op, after a ` -- `.
        if (std.mem.lastIndexOf(u8, left, "--")) |li| {
            const lbl = std.mem.trim(u8, left[li + 2 ..], ws);
            if (lbl.len > 0) {
                label = std.mem.trim(u8, lbl, "\"");
                left = std.mem.trim(u8, left[0..li], ws);
            }
        }
        // `-->|label|`
        if (right.len > 0 and right[0] == '|') {
            if (std.mem.indexOfScalarPos(u8, right, 1, '|')) |bar| {
                label = std.mem.trim(u8, right[1..bar], ws);
                right = std.mem.trim(u8, right[bar + 1 ..], ws);
            }
        }
        const from = firstId(left);
        const to = firstId(right);
        if (from.len == 0 or to.len == 0) return null;
        return .{ .from = from, .to = to, .label = label };
    }
    return null;
}

fn firstId(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, ws);
    var i: usize = 0;
    while (i < t.len and isIdentChar(t[i])) i += 1;
    return t[0..i];
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

fn ceilDiv(a: usize, b: usize) usize {
    return if (b == 0) a else (a + b - 1) / b;
}

// --- drawing helpers ---

const BoxGlyphs = @import("canvas.zig").BoxGlyphs;
const drawBox = @import("canvas.zig").drawBox;
const canvas = @import("canvas.zig");

fn putCentered(c: Canvas, x: usize, w: usize, row: usize, s: []const u8) void {
    if (w < 3) return;
    canvas.putCentered(c, x + 1, w - 2, row, clip(s, w - 2));
}

const clip = text.clip;

test "block lays out a columns grid with labels and spans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "block-beta\n" ++
        "columns 3\n" ++
        "a[\"Alpha\"] b[\"Beta\"] c[\"Gamma\"]\n" ++
        "d[\"Wide\"]:3\n";
    const art = try render(arena.allocator(), src, true);
    for ([_][]const u8{ "Alpha", "Beta", "Gamma", "Wide" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, art, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, art, "+") != null); // ascii box corners
    // The spanning block (d:3) sits on its own row below the three columns.
    var lines = std.mem.splitScalar(u8, art, '\n');
    var alpha_row: ?usize = null;
    var wide_row: ?usize = null;
    var r: usize = 0;
    while (lines.next()) |ln| : (r += 1) {
        if (std.mem.indexOf(u8, ln, "Alpha") != null) alpha_row = r;
        if (std.mem.indexOf(u8, ln, "Wide") != null) wide_row = r;
    }
    try std.testing.expect(alpha_row != null and wide_row != null);
    try std.testing.expect(wide_row.? > alpha_row.?);
}

test "block survives an unclosed bracket token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "block-beta\n" ++
        "a[\n" ++
        "b[\"Beta\" c\n";
    const art = try render(arena.allocator(), src, true);
    try std.testing.expect(std.mem.indexOf(u8, art, "Beta") != null);
}

test "block renders nested groups and arrows with labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "block-beta\n" ++
        "columns 1\n" ++
        "block:grp[\"Group\"]\n" ++
        "  columns 2\n" ++
        "  x[\"X\"] y[\"Y\"]\n" ++
        "end\n" ++
        "z[\"Z\"]\n" ++
        "grp --> z\n";
    const art = try render(arena.allocator(), src, true);
    for ([_][]const u8{ "Group", "X", "Y", "Z" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, art, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, art, "v") != null); // downward arrowhead (grp above z)
}

test "block ascii vs unicode box glyphs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "block-beta\ncolumns 2\na[\"A\"] b[\"B\"]\n";
    const uni = try render(arena.allocator(), src, false);
    try std.testing.expect(std.mem.indexOf(u8, uni, "\u{250C}") != null); // ┌ corner
    const asc = try render(arena.allocator(), src, true);
    try std.testing.expect(std.mem.indexOf(u8, asc, "\u{250C}") == null); // ┌
    try std.testing.expect(std.mem.indexOf(u8, asc, "+") != null);
}

test "matchBracket finds the matching closer, nesting- and quote-aware" {
    try std.testing.expectEqual(@as(?usize, 4), matchBracket("[abc]"));
    try std.testing.expectEqual(@as(?usize, 6), matchBracket("(a(b)c)")); // nested pair
    try std.testing.expectEqual(@as(?usize, 6), matchBracket("[a\"]\"b]")); // ] inside quotes ignored
    try std.testing.expectEqual(@as(?usize, null), matchBracket("[unclosed"));
}

test "parseArrow reads endpoints and pre/post/pipe labels" {
    const a = parseArrow("A --> B").?;
    try std.testing.expectEqualStrings("A", a.from);
    try std.testing.expectEqualStrings("B", a.to);
    try std.testing.expectEqualStrings("", a.label);
    try std.testing.expectEqualStrings("yes", parseArrow("A -->|yes| B").?.label);
    const c = parseArrow("A -- maybe --> B").?;
    try std.testing.expectEqualStrings("A", c.from);
    try std.testing.expectEqualStrings("B", c.to);
    try std.testing.expectEqualStrings("maybe", c.label);
    const d = parseArrow("X -.-> Y").?;
    try std.testing.expectEqualStrings("X", d.from);
    try std.testing.expectEqualStrings("Y", d.to);
    try std.testing.expect(parseArrow("no arrow here") == null);
}

test "classify reads id, bracketed label and :N span" {
    const a = classify("id1[In progress]:2");
    try std.testing.expectEqualStrings("id1", a.id);
    try std.testing.expectEqualStrings("In progress", a.label);
    try std.testing.expectEqual(@as(usize, 2), a.span);
    const b = classify("A");
    try std.testing.expectEqualStrings("A", b.id);
    try std.testing.expectEqualStrings("A", b.label); // label defaults to the id
    try std.testing.expectEqual(@as(usize, 1), b.span); // default span
}
