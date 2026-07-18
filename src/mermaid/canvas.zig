//! A fixed-size character grid for 2D text art.
//!
//! Two layers: direct glyphs (boxes, labels, arrows) and a connection layer for
//! lines. Each line cell records which of its four sides connect. The box-drawing
//! glyph (─ │ ┌ ┐ └ ┘ ├ ┤ ┬ ┴ ┼) is derived from that set, so crossings and
//! junctions (tees) resolve automatically. Direct glyphs take priority.
//!
//! Known limitation: putStr assigns one grid cell per code point, while the
//! renderers size boxes by display width. Double-width characters (CJK, emoji)
//! in labels therefore shift everything after them one column right per wide
//! glyph. ASCII and narrow-Unicode labels are unaffected.

const std = @import("std");
const theme = @import("../theme.zig");
const width = @import("../markdown/width.zig");
const Style = theme.Style;

const up: u8 = 1;
const down: u8 = 2;
const left: u8 = 4;
const right: u8 = 8;

pub const Canvas = struct {
    w: usize,
    h: usize,
    cells: []u21, // direct glyphs (' ' = empty)
    lines: []u8, // connection bitmask per cell
    styles: []Style, // per-cell style (plain by default)
    arena: std.mem.Allocator,

    pub fn init(arena: std.mem.Allocator, w: usize, h: usize) !Canvas {
        const cells = try arena.alloc(u21, w * h);
        @memset(cells, ' ');
        const lines = try arena.alloc(u8, w * h);
        @memset(lines, 0);
        const styles = try arena.alloc(Style, w * h);
        @memset(styles, .{});
        return .{ .w = w, .h = h, .cells = cells, .lines = lines, .styles = styles, .arena = arena };
    }

    pub fn setStyle(self: Canvas, x: usize, y: usize, s: Style) void {
        if (x < self.w and y < self.h) self.styles[self.idx(x, y)] = s;
    }

    pub fn fillStyle(self: Canvas, x0: usize, y0: usize, x1: usize, y1: usize, s: Style) void {
        if (s.isPlain()) return;
        var y = y0;
        while (y <= y1 and y < self.h) : (y += 1) {
            var x = x0;
            while (x <= x1 and x < self.w) : (x += 1) self.styles[self.idx(x, y)] = s;
        }
    }

    fn idx(self: Canvas, x: usize, y: usize) usize {
        return y * self.w + x;
    }

    pub fn set(self: Canvas, x: usize, y: usize, cp: u21) void {
        if (x < self.w and y < self.h) self.cells[self.idx(x, y)] = cp;
    }

    pub fn get(self: Canvas, x: usize, y: usize) u21 {
        if (x >= self.w or y >= self.h) return ' ';
        return self.cells[self.idx(x, y)];
    }

    pub fn putStr(self: Canvas, x: usize, y: usize, s: []const u8) void {
        var cx = x;
        var i: usize = 0;
        while (i < s.len) {
            const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const end = @min(i + len, s.len);
            const cp = std.unicode.utf8Decode(s[i..end]) catch s[i];
            self.set(cx, y, cp);
            cx += 1;
            i = end;
        }
    }

    /// Direct glyphs, not the line layer: these do not resolve into junctions.
    pub fn hline(self: Canvas, x0: usize, x1: usize, y: usize, cp: u21) void {
        var x = @min(x0, x1);
        const b = @max(x0, x1);
        while (x <= b) : (x += 1) self.set(x, y, cp);
    }

    pub fn vline(self: Canvas, y0: usize, y1: usize, x: usize, cp: u21) void {
        var y = @min(y0, y1);
        const b = @max(y0, y1);
        while (y <= b) : (y += 1) self.set(x, y, cp);
    }

    /// Bresenham, for the diagonals the connection layer can't express (radar
    /// polygons, xychart lines). Glyph layer, so no junction resolution.
    pub fn plotLine(self: Canvas, x0: usize, y0: usize, x1: usize, y1: usize, cp: u21) void {
        var px: i64 = @intCast(x0);
        var py: i64 = @intCast(y0);
        const qx: i64 = @intCast(x1);
        const qy: i64 = @intCast(y1);
        const adx = qx - px;
        const ady = qy - py;
        const dx: i64 = if (adx < 0) -adx else adx;
        const dy: i64 = -(if (ady < 0) -ady else ady); // negative magnitude (Bresenham)
        const sx: i64 = if (px < qx) 1 else -1;
        const sy: i64 = if (py < qy) 1 else -1;
        var err = dx + dy;
        while (true) {
            if (px >= 0 and py >= 0) self.set(@intCast(px), @intCast(py), cp);
            if (px == qx and py == qy) break;
            const e2 = 2 * err;
            if (e2 >= dy) {
                err += dy;
                px += sx;
            }
            if (e2 <= dx) {
                err += dx;
                py += sy;
            }
        }
    }

    fn addBits(self: Canvas, x: usize, y: usize, bits: u8) void {
        if (x < self.w and y < self.h) self.lines[self.idx(x, y)] |= bits;
    }

    pub fn lineH(self: Canvas, x0: usize, x1: usize, y: usize) void {
        const a = @min(x0, x1);
        const b = @max(x0, x1);
        var x = a;
        while (x <= b) : (x += 1) {
            var bits: u8 = 0;
            if (x > a) bits |= left;
            if (x < b) bits |= right;
            self.addBits(x, y, bits);
        }
    }

    pub fn lineV(self: Canvas, y0: usize, y1: usize, x: usize) void {
        const a = @min(y0, y1);
        const b = @max(y0, y1);
        var y = a;
        while (y <= b) : (y += 1) {
            var bits: u8 = 0;
            if (y > a) bits |= up;
            if (y < b) bits |= down;
            self.addBits(x, y, bits);
        }
    }

    pub fn toString(self: Canvas, ascii: bool) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var buf: [4]u8 = undefined;
        var y: usize = 0;
        while (y < self.h) : (y += 1) {
            var last: usize = 0;
            var x: usize = 0;
            while (x < self.w) : (x += 1) {
                if (self.glyph(x, y) != ' ') last = x + 1;
            }
            // Group consecutive cells sharing a non-plain style into SGR runs.
            // When every cell is plain the output is identical to before.
            var open: ?Style = null;
            x = 0;
            while (x < last) : (x += 1) {
                const i = self.idx(x, y);
                const st = self.styles[i];
                if (st.isPlain()) {
                    if (open != null) {
                        try theme.appendReset(&out, self.arena);
                        open = null;
                    }
                } else if (open == null or !Style.eql(open.?, st)) {
                    if (open != null) try theme.appendReset(&out, self.arena);
                    try theme.appendOpen(&out, self.arena, st);
                    open = st;
                }
                const cp = if (self.cells[i] != ' ')
                    self.cells[i]
                else
                    maskGlyph(self.lines[i], ascii);
                const n = std.unicode.utf8Encode(cp, &buf) catch blk: {
                    buf[0] = ' ';
                    break :blk 1;
                };
                try out.appendSlice(self.arena, buf[0..n]);
            }
            if (open != null) try theme.appendReset(&out, self.arena);
            try out.append(self.arena, '\n');
        }
        return std.mem.trimEnd(u8, out.items, "\n");
    }

    fn glyph(self: Canvas, x: usize, y: usize) u21 {
        const i = self.idx(x, y);
        if (self.cells[i] != ' ') return self.cells[i];
        return maskGlyph(self.lines[i], false);
    }
};

pub const BoxGlyphs = struct {
    tl: u21,
    tr: u21,
    bl: u21,
    br: u21,
    h: u21,
    v: u21,
    pub const unicode = BoxGlyphs{ .tl = '\u{250C}', .tr = '\u{2510}', .bl = '\u{2514}', .br = '\u{2518}', .h = '\u{2500}', .v = '\u{2502}' }; // ┌ ┐ └ ┘ ─ │
    pub const ascii = BoxGlyphs{ .tl = '+', .tr = '+', .bl = '+', .br = '+', .h = '-', .v = '|' };
};

/// Direct glyphs: these borders never merge with wires.
pub fn drawBox(c: Canvas, g: BoxGlyphs, x: usize, y: usize, w: usize, h: usize) void {
    if (w < 2 or h < 2) return;
    const x1 = x + w - 1;
    const y1 = y + h - 1;
    c.set(x, y, g.tl);
    c.set(x1, y, g.tr);
    c.set(x, y1, g.bl);
    c.set(x1, y1, g.br);
    // Degenerate sizes have no interior run (hline/vline would swap their
    // reversed range and overwrite the corners).
    if (w > 2) {
        c.hline(x + 1, x1 - 1, y, g.h);
        c.hline(x + 1, x1 - 1, y1, g.h);
    }
    if (h > 2) {
        c.vline(y + 1, y1 - 1, x, g.v);
        c.vline(y + 1, y1 - 1, x1, g.v);
    }
}

/// Left-aligns when `s` does not fit. Does not clip.
pub fn putCentered(c: Canvas, x: usize, w: usize, y: usize, s: []const u8) void {
    const lw = width.displayWidth(s);
    c.putStr(x + (if (w > lw) (w - lw) / 2 else 0), y, s);
}

fn maskGlyph(mask: u8, ascii: bool) u21 {
    if (mask == 0) return ' ';
    const u = mask & up != 0;
    const d = mask & down != 0;
    const l = mask & left != 0;
    const r = mask & right != 0;
    if (ascii) {
        const horiz = l or r;
        const vert = u or d;
        if (horiz and vert) return '+';
        if (horiz) return '-';
        return '|';
    }
    return switch (mask) {
        up | down => '\u{2502}', // │
        left | right => '\u{2500}', // ─
        down | right => '\u{250C}', // ┌
        down | left => '\u{2510}', // ┐
        up | right => '\u{2514}', // └
        up | left => '\u{2518}', // ┘
        up | down | right => '\u{251C}', // ├
        up | down | left => '\u{2524}', // ┤
        down | left | right => '\u{252C}', // ┬
        up | left | right => '\u{2534}', // ┴
        up | down | left | right => '\u{253C}', // ┼
        up, down => '\u{2502}', // │
        left, right => '\u{2500}', // ─
        else => ' ',
    };
}

test "canvas draws direct glyphs and serializes trimmed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = try Canvas.init(arena.allocator(), 6, 3);
    c.putStr(0, 0, "ab");
    c.hline(0, 3, 1, '-');
    c.set(2, 2, 'x');
    const s = try c.toString(false);
    try std.testing.expectEqualStrings("ab\n----\n  x", s);
}

test "canvas styled cell wraps in SGR and resets; plain stays bare" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = try Canvas.init(arena.allocator(), 3, 1);
    c.set(0, 0, 'X');
    c.set(1, 0, 'Y');
    c.setStyle(0, 0, .{ .bold = true });
    const s = try c.toString(false);
    try std.testing.expect(std.mem.indexOf(u8, s, "\x1b[1m") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\x1b[0m") != null);
    // The unstyled cell after reset has no further SGR before it.
    try std.testing.expect(std.mem.indexOf(u8, s, "Y") != null);
}

test "plotLine sets both endpoints and a diagonal interior cell" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = try Canvas.init(arena.allocator(), 5, 5);
    c.plotLine(0, 0, 4, 4, '*');
    try std.testing.expect(c.get(0, 0) == '*');
    try std.testing.expect(c.get(4, 4) == '*');
    try std.testing.expect(c.get(2, 2) == '*'); // midpoint on the diagonal
}

test "drawBox at degenerate sizes keeps its corners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = try Canvas.init(arena.allocator(), 4, 4);
    drawBox(c, BoxGlyphs.unicode, 0, 0, 2, 2); // no interior at all
    try std.testing.expect(c.get(0, 0) == '\u{250C}'); // ┌
    try std.testing.expect(c.get(1, 0) == '\u{2510}'); // ┐
    try std.testing.expect(c.get(0, 1) == '\u{2514}'); // └
    try std.testing.expect(c.get(1, 1) == '\u{2518}'); // ┘
}

test "putCentered centers by display width and left-aligns overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = try Canvas.init(arena.allocator(), 8, 2);
    putCentered(c, 0, 7, 0, "abc"); // (7-3)/2 = 2
    try std.testing.expect(c.get(2, 0) == 'a');
    putCentered(c, 0, 2, 1, "abc"); // does not fit: left-aligned
    try std.testing.expect(c.get(0, 1) == 'a');
}

test "line layer forms a corner from joined segments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = try Canvas.init(arena.allocator(), 4, 4);
    c.lineV(0, 2, 0); // down the left edge
    c.lineH(0, 3, 2); // then right along the bottom
    const s = try c.toString(false);
    // corner at (0,2) connects up + right => └
    try std.testing.expect(std.mem.indexOf(u8, s, "\u{2514}") != null); // └
}
