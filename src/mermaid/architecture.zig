//! Syntax Ref: https://mermaid.ai/open-source/syntax/architecture.html
//!
//! Services and junctions on a constraint grid.
//!
//! An edge declares the face it leaves and the face it enters (`a:L`, `R:b`). The
//! leaving face fixes b's position relative to a, and coordinates propagate by
//! BFS. Edge overlaps and crossings are not resolved.

const std = @import("std");
const Canvas = @import("canvas.zig").Canvas;
const putCentered = @import("canvas.zig").putCentered;
const width = @import("../markdown/width.zig");
const text = @import("text.zig");

const ws = text.ws;
const h_gap: usize = 6; // horizontal space between columns (wire + arrow)
const v_gap: usize = 2; // vertical space between rows
const margin: usize = 3; // border for group bounding boxes

const Side = enum {
    l,
    r,
    t,
    b,
    fn off(s: Side) [2]i32 {
        return switch (s) {
            .l => .{ -1, 0 },
            .r => .{ 1, 0 },
            .t => .{ 0, -1 },
            .b => .{ 0, 1 },
        };
    }
};

const Node = struct {
    id: []const u8,
    title: []const u8,
    icon: []const u8,
    group: []const u8,
    junction: bool,
};
const Group = struct { id: []const u8, title: []const u8 };
const Edge = struct { a: usize, b: usize, sa: Side, sb: Side, head_a: bool, head_b: bool };

pub fn render(arena: std.mem.Allocator, src: []const u8, ascii_mode: bool) ![]const u8 {
    const doc = try parse(arena, src);
    if (doc.nodes.len == 0) return error.Empty;
    var l = Layouter{ .arena = arena, .doc = doc, .ascii = ascii_mode };
    try l.placeGrid();
    try l.computeGeometry();
    return l.draw();
}

const Parsed = struct { nodes: []Node, groups: []Group, edges: []Edge };

/// Edges resolve only after the whole source is read, since services may be
/// declared after the edges using them. Edges naming unknown services are dropped.
fn parse(arena: std.mem.Allocator, src: []const u8) !Parsed {
    var nodes: std.ArrayList(Node) = .empty;
    var groups: std.ArrayList(Group) = .empty;
    var raw_edges: std.ArrayList(EdgeSpec) = .empty;
    var nindex: std.StringHashMap(usize) = .init(arena);

    var it = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, ws);
        if (first) {
            first = false;
            continue; // skip "architecture" / "architecture-beta"
        }
        if (t.len == 0 or std.mem.startsWith(u8, t, "%%")) continue;
        if (std.mem.startsWith(u8, t, "group ")) {
            const d = parseDecl(t[6..]);
            try groups.append(arena, .{ .id = d.id, .title = if (d.title.len > 0) d.title else d.id });
            continue;
        }
        if (std.mem.startsWith(u8, t, "service ")) {
            const d = parseDecl(t[8..]);
            try nindex.put(d.id, nodes.items.len);
            try nodes.append(arena, .{ .id = d.id, .title = if (d.title.len > 0) d.title else d.id, .icon = d.icon, .group = d.group, .junction = false });
            continue;
        }
        if (std.mem.startsWith(u8, t, "junction ")) {
            const d = parseDecl(t[9..]);
            try nindex.put(d.id, nodes.items.len);
            try nodes.append(arena, .{ .id = d.id, .title = "", .icon = "", .group = d.group, .junction = true });
            continue;
        }
        if (parseEdge(t)) |e| try raw_edges.append(arena, e);
    }

    var edges: std.ArrayList(Edge) = .empty;
    for (raw_edges.items) |e| {
        const ai = nindex.get(e.a_id) orelse continue;
        const bi = nindex.get(e.b_id) orelse continue;
        try edges.append(arena, .{ .a = ai, .b = bi, .sa = e.sa, .sb = e.sb, .head_a = e.head_a, .head_b = e.head_b });
    }
    return .{ .nodes = nodes.items, .groups = groups.items, .edges = edges.items };
}

/// Layouter carries the parsed document through the layout phases:
/// placeGrid (grid coordinates) → computeGeometry (pixel boxes) → draw.
const Layouter = struct {
    arena: std.mem.Allocator,
    doc: Parsed,
    ascii: bool,

    // Grid coordinates per node (placeGrid).
    gx: []i32 = &.{},
    gy: []i32 = &.{},
    // Pixel geometry per node + canvas size (computeGeometry).
    bw: []usize = &.{},
    bh: []usize = &.{},
    px: []usize = &.{},
    py: []usize = &.{},
    canvas_w: usize = 0,
    canvas_h: usize = 0,

    /// BFS over the port-constraint graph, per component. Components stack by row.
    fn placeGrid(self: *Layouter) !void {
        const arena = self.arena;
        const n = self.doc.nodes.len;
        const adj = try buildAdj(arena, n, self.doc.edges);
        const gx = try arena.alloc(i32, n);
        const gy = try arena.alloc(i32, n);
        const placed = try arena.alloc(bool, n);
        @memset(placed, false);
        var queue: std.ArrayList(usize) = .empty;
        var comp: std.ArrayList(usize) = .empty;
        var row_base: i32 = 0;
        for (0..n) |seed| {
            if (placed[seed]) continue;
            gx[seed] = 0;
            gy[seed] = 0;
            placed[seed] = true;
            queue.clearRetainingCapacity();
            comp.clearRetainingCapacity();
            try queue.append(arena, seed);
            try comp.append(arena, seed);
            var qi: usize = 0;
            while (qi < queue.items.len) : (qi += 1) {
                const u = queue.items[qi];
                for (adj[u].items) |lnk| {
                    if (placed[lnk.to]) continue;
                    gx[lnk.to] = gx[u] + lnk.dx;
                    gy[lnk.to] = gy[u] + lnk.dy;
                    placed[lnk.to] = true;
                    try queue.append(arena, lnk.to);
                    try comp.append(arena, lnk.to);
                }
            }
            // Normalise this component: gx≥0 and gy shifted below previous ones.
            var minx: i32 = std.math.maxInt(i32);
            var miny: i32 = std.math.maxInt(i32);
            for (comp.items) |i| {
                minx = @min(minx, gx[i]);
                miny = @min(miny, gy[i]);
            }
            var maxy: i32 = std.math.minInt(i32);
            for (comp.items) |i| {
                gx[i] -= minx;
                gy[i] = gy[i] - miny + row_base;
                maxy = @max(maxy, gy[i]);
            }
            row_base = maxy + 1;
        }
        self.gx = gx;
        self.gy = gy;
    }

    /// Grid coordinates to pixel columns/rows.
    fn computeGeometry(self: *Layouter) !void {
        const arena = self.arena;
        const nodes = self.doc.nodes;
        const n = nodes.len;
        const xs = try sortedUnique(arena, self.gx, n);
        const ys = try sortedUnique(arena, self.gy, n);
        const col = try arena.alloc(usize, n);
        const row = try arena.alloc(usize, n);
        for (0..n) |i| {
            col[i] = indexOf(xs, self.gx[i]);
            row[i] = indexOf(ys, self.gy[i]);
        }
        const bw = try arena.alloc(usize, n);
        const bh = try arena.alloc(usize, n);
        for (0..n) |i| {
            if (nodes[i].junction) {
                bw[i] = 1;
                bh[i] = 1;
            } else {
                bw[i] = width.displayWidth(labelOf(arena, nodes[i], self.ascii)) + 4;
                bh[i] = 3;
            }
        }
        const col_w = try arena.alloc(usize, xs.len);
        @memset(col_w, 1);
        const row_h = try arena.alloc(usize, ys.len);
        @memset(row_h, 1);
        for (0..n) |i| {
            col_w[col[i]] = @max(col_w[col[i]], bw[i]);
            row_h[row[i]] = @max(row_h[row[i]], bh[i]);
        }
        const col_x = try arena.alloc(usize, xs.len);
        var cx: usize = margin;
        for (0..xs.len) |c| {
            col_x[c] = cx;
            cx += col_w[c] + h_gap;
        }
        const row_y = try arena.alloc(usize, ys.len);
        var cy: usize = margin;
        for (0..ys.len) |r| {
            row_y[r] = cy;
            cy += row_h[r] + v_gap;
        }
        self.canvas_w = cx + margin;
        self.canvas_h = cy + margin;

        // Node box top-left positions (centred within their column/row band).
        const px = try arena.alloc(usize, n);
        const py = try arena.alloc(usize, n);
        for (0..n) |i| {
            px[i] = col_x[col[i]] + (col_w[col[i]] - bw[i]) / 2;
            py[i] = row_y[row[i]] + (row_h[row[i]] - bh[i]) / 2;
        }
        self.bw = bw;
        self.bh = bh;
        self.px = px;
        self.py = py;
    }

    /// Groups, wires, service boxes, arrowheads: later layers sit on top.
    fn draw(self: *Layouter) ![]const u8 {
        const nodes = self.doc.nodes;
        const n = nodes.len;
        const px = self.px;
        const py = self.py;
        const bw = self.bw;
        const bh = self.bh;
        var c = try Canvas.init(self.arena, self.canvas_w, self.canvas_h);
        const box = if (self.ascii) BoxGlyphs.ascii else BoxGlyphs.unicode;

        // 1) group bounding boxes (under everything).
        for (self.doc.groups) |grp| {
            var x0: usize = std.math.maxInt(usize);
            var y0: usize = std.math.maxInt(usize);
            var x1: usize = 0;
            var y1: usize = 0;
            var any = false;
            for (0..n) |i| {
                if (!std.mem.eql(u8, nodes[i].group, grp.id)) continue;
                any = true;
                x0 = @min(x0, px[i]);
                y0 = @min(y0, py[i]);
                x1 = @max(x1, px[i] + bw[i] - 1);
                y1 = @max(y1, py[i] + bh[i] - 1);
            }
            if (!any) continue;
            const gx0 = if (x0 >= 2) x0 - 2 else 0;
            const gy0 = if (y0 >= 2) y0 - 2 else 0;
            var gx1 = @min(x1 + 2, self.canvas_w - 1);
            const gy1 = @min(y1 + 1, self.canvas_h - 1);
            // Widen for the title if needed.
            const need = width.displayWidth(grp.title) + 2;
            if (gx1 < gx0 + need) gx1 = @min(gx0 + need, self.canvas_w - 1);
            drawBox(c, box, gx0, gy0, gx1 - gx0 + 1, gy1 - gy0 + 1);
            if (gx0 + 2 < gx1) c.putStr(gx0 + 2, gy0, grp.title);
        }

        // 2) wires on the connection layer.
        for (self.doc.edges) |e| {
            const pa = portCell(px[e.a], py[e.a], bw[e.a], bh[e.a], e.sa);
            const pb = portCell(px[e.b], py[e.b], bw[e.b], bh[e.b], e.sb);
            if (e.sa == .l or e.sa == .r) {
                c.lineH(pa.x, pb.x, pa.y);
                c.lineV(pa.y, pb.y, pb.x);
            } else {
                c.lineV(pa.y, pb.y, pa.x);
                c.lineH(pa.x, pb.x, pb.y);
            }
        }

        // 3) service boxes (over the wires).
        for (0..n) |i| {
            if (nodes[i].junction) continue;
            drawBox(c, box, px[i], py[i], bw[i], bh[i]);
            const label = labelOf(self.arena, nodes[i], self.ascii);
            putCentered(c, px[i] + 1, bw[i] - 2, py[i] + 1, label);
        }

        // 4) arrowheads (over the wires, at the entered face).
        for (self.doc.edges) |e| {
            if (e.head_b) {
                const pb = portCell(px[e.b], py[e.b], bw[e.b], bh[e.b], e.sb);
                c.set(pb.x, pb.y, arrowGlyph(e.sb, self.ascii));
            }
            if (e.head_a) {
                const pa = portCell(px[e.a], py[e.a], bw[e.a], bh[e.a], e.sa);
                c.set(pa.x, pa.y, arrowGlyph(e.sa, self.ascii));
            }
        }

        return c.toString(self.ascii);
    }
};

const Link = struct { to: usize, dx: i32, dy: i32 };

fn buildAdj(arena: std.mem.Allocator, n: usize, edges: []const Edge) ![]std.ArrayList(Link) {
    const adj = try arena.alloc(std.ArrayList(Link), n);
    for (adj) |*a| a.* = .empty;
    for (edges) |e| {
        const d = e.sa.off();
        try adj[e.a].append(arena, .{ .to = e.b, .dx = d[0], .dy = d[1] });
        try adj[e.b].append(arena, .{ .to = e.a, .dx = -d[0], .dy = -d[1] });
    }
    return adj;
}

const Port = struct { x: usize, y: usize };

/// The cell just outside the box on `side`, where the wire attaches and the
/// arrowhead sits.
fn portCell(bx: usize, by: usize, w: usize, h: usize, side: Side) Port {
    const cx = bx + w / 2;
    const cy = by + h / 2;
    return switch (side) {
        .l => .{ .x = if (bx > 0) bx - 1 else 0, .y = cy },
        .r => .{ .x = bx + w, .y = cy },
        .t => .{ .x = cx, .y = if (by > 0) by - 1 else 0 },
        .b => .{ .x = cx, .y = by + h },
    };
}

fn arrowGlyph(side: Side, ascii: bool) u21 {
    return switch (side) {
        .l => if (ascii) '>' else '\u{25B6}', // enters left face → points right ▶
        .r => if (ascii) '<' else '\u{25C0}', // ◀
        .t => if (ascii) 'v' else '\u{25BC}', // ▼
        .b => if (ascii) '^' else '\u{25B2}', // ▲
    };
}

const BoxGlyphs = @import("canvas.zig").BoxGlyphs;
const drawBox = @import("canvas.zig").drawBox;

fn labelOf(arena: std.mem.Allocator, node: Node, ascii: bool) []const u8 {
    const glyph = if (ascii) "" else iconGlyph(node.icon);
    if (glyph.len == 0) return node.title;
    return std.fmt.allocPrint(arena, "{s} {s}", .{ glyph, node.title }) catch node.title;
}

/// A single-width glyph, or "" when the icon is unknown, so the label shows alone.
fn iconGlyph(icon: []const u8) []const u8 {
    const map = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "database", .v = "\u{25AD}" }, // ▭
        .{ .k = "server", .v = "\u{25A3}" }, // ▣
        .{ .k = "disk", .v = "\u{25A4}" }, // ▤
        .{ .k = "cloud", .v = "\u{25C7}" }, // ◇
        .{ .k = "internet", .v = "\u{25C9}" }, // ◉
    };
    for (map) |m| if (std.mem.eql(u8, icon, m.k)) return m.v;
    return "";
}

const Decl = struct { id: []const u8, icon: []const u8, title: []const u8, group: []const u8 };

/// `id(icon)[title] [in group]`, from a declaration tail.
fn parseDecl(s0: []const u8) Decl {
    var s = std.mem.trim(u8, s0, ws);
    var d = Decl{ .id = "", .icon = "", .title = "", .group = "" };
    // Trailing "in group".
    if (std.mem.lastIndexOf(u8, s, " in ")) |i| {
        d.group = std.mem.trim(u8, s[i + 4 ..], ws);
        s = std.mem.trim(u8, s[0..i], ws);
    }
    // id up to '(' or '['.
    const stop = std.mem.indexOfAny(u8, s, "([") orelse s.len;
    d.id = std.mem.trim(u8, s[0..stop], ws);
    var rest = s[stop..];
    if (rest.len > 0 and rest[0] == '(') {
        if (std.mem.indexOfScalar(u8, rest, ')')) |c| {
            d.icon = std.mem.trim(u8, rest[1..c], ws);
            rest = rest[c + 1 ..];
        }
    }
    if (std.mem.indexOfScalar(u8, rest, '[')) |o| {
        if (std.mem.indexOfScalarPos(u8, rest, o, ']')) |c| {
            d.title = std.mem.trim(u8, rest[o + 1 .. c], ws);
        }
    }
    return d;
}

const EdgeSpec = struct { a_id: []const u8, b_id: []const u8, sa: Side, sb: Side, head_a: bool, head_b: bool };

const arrow_ops = [_][]const u8{ "<-->", "-->", "<--", "--" };

/// `a:SideA <op> SideB:b`. Null when the line has no arrow op.
fn parseEdge(t: []const u8) ?EdgeSpec {
    for (arrow_ops) |op| {
        const idx = std.mem.indexOf(u8, t, op) orelse continue;
        const left = std.mem.trim(u8, t[0..idx], ws);
        const right = std.mem.trim(u8, t[idx + op.len ..], ws);
        if (left.len == 0 or right.len == 0) return null;
        const le = splitLeft(left); // "id:side"
        const re = splitRight(right); // "side:id"
        const head_b = std.mem.eql(u8, op, "-->") or std.mem.eql(u8, op, "<-->");
        const head_a = std.mem.eql(u8, op, "<--") or std.mem.eql(u8, op, "<-->");
        return .{ .a_id = le.id, .b_id = re.id, .sa = le.side, .sb = re.side, .head_a = head_a, .head_b = head_b };
    }
    return null;
}

const EndA = struct { id: []const u8, side: Side };
fn splitLeft(s: []const u8) EndA {
    if (std.mem.lastIndexOfScalar(u8, s, ':')) |c| {
        return .{ .id = std.mem.trim(u8, s[0..c], ws), .side = parseSide(std.mem.trim(u8, s[c + 1 ..], ws), .r) };
    }
    return .{ .id = s, .side = .r };
}
fn splitRight(s: []const u8) EndA {
    if (std.mem.indexOfScalar(u8, s, ':')) |c| {
        return .{ .id = std.mem.trim(u8, s[c + 1 ..], ws), .side = parseSide(std.mem.trim(u8, s[0..c], ws), .l) };
    }
    return .{ .id = s, .side = .l };
}

fn parseSide(s: []const u8, default: Side) Side {
    if (s.len == 0) return default;
    return switch (std.ascii.toUpper(s[0])) {
        'L' => .l,
        'R' => .r,
        'T' => .t,
        'B' => .b,
        else => default,
    };
}

fn sortedUnique(arena: std.mem.Allocator, vals: []const i32, n: usize) ![]i32 {
    var list: std.ArrayList(i32) = .empty;
    for (0..n) |i| {
        var seen = false;
        for (list.items) |v| if (v == vals[i]) {
            seen = true;
            break;
        };
        if (!seen) try list.append(arena, vals[i]);
    }
    std.mem.sort(i32, list.items, {}, std.sort.asc(i32));
    return list.items;
}

fn indexOf(sorted: []const i32, v: i32) usize {
    for (sorted, 0..) |x, i| if (x == v) return i;
    return 0;
}

test "architecture places services and wires them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "architecture-beta\n" ++
        "group api(cloud)[API]\n" ++
        "service db(database)[Database] in api\n" ++
        "service server(server)[Server] in api\n" ++
        "service disk1(disk)[Storage] in api\n" ++
        "db:L -- R:server\n" ++
        "disk1:T -- B:server\n";
    const art = try render(arena.allocator(), src, true);
    for ([_][]const u8{ "Database", "Server", "Storage", "API" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, art, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, art, "+") != null); // ascii box corners
    try std.testing.expect(std.mem.indexOf(u8, art, "-") != null); // wires / borders
}

test "architecture arrowheads and junction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "architecture-beta\n" ++
        "service a(server)[A]\n" ++
        "service b(server)[B]\n" ++
        "junction j\n" ++
        "a:R --> L:b\n" ++
        "a:B -- T:j\n";
    const art = try render(arena.allocator(), src, true);
    try std.testing.expect(std.mem.indexOf(u8, art, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "B") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, ">") != null); // ascii arrowhead
}

test "architecture unicode icon glyph prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "architecture-beta\n" ++
        "service db(database)[Database]\n" ++
        "service srv(server)[Server]\n" ++
        "db:R -- L:srv\n";
    const art = try render(arena.allocator(), src, false);
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{25AD}") != null); // database glyph ▭
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{25A3}") != null); // server glyph ▣
}
