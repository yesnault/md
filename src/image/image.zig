//! Renders diagram art to a terminal "image": half-blocks (▀) with truecolor,
//! two vertical pixels per cell. The art is rasterized with the embedded font8x8,
//! then box-downscaled to a column budget. Image mode forces ASCII art, since the
//! font only covers ASCII.

const std = @import("std");
const font = @import("font8x8.zig");

const Bitmap = struct { w: usize, h: usize, px: []u8 };

/// Half-blocks image of `art` fitted to `cols` terminal columns, one pixel per
/// column. Newline-separated, caller may indent. Null on empty art.
pub fn render(arena: std.mem.Allocator, art: []const u8, cols: usize) !?[]const u8 {
    const bmp = try rasterize(arena, art);
    if (bmp.w == 0 or bmp.h == 0) return null;

    const tw = @min(bmp.w, @max(cols, 1));
    const th = @max((bmp.h * tw) / bmp.w, 1);
    const gray = try downscale(arena, bmp, tw, th);

    var out: std.ArrayList(u8) = .empty;
    var buf: [48]u8 = undefined;
    var r: usize = 0;
    while (r * 2 < th) : (r += 1) {
        var x: usize = 0;
        while (x < tw) : (x += 1) {
            const top = gray[(r * 2) * tw + x];
            const bottom = if (r * 2 + 1 < th) gray[(r * 2 + 1) * tw + x] else 0;
            const seq = try std.fmt.bufPrint(&buf, "\x1b[38;2;{d};{d};{d};48;2;{d};{d};{d}m\u{2580}", .{ top, top, top, bottom, bottom, bottom });
            try out.appendSlice(arena, seq);
        }
        try out.appendSlice(arena, "\x1b[0m\n");
    }
    return std.mem.trimEnd(u8, out.items, "\n");
}

/// Kitty graphics escape (raw RGB, base64, chunked) displaying `art` within `cols`
/// columns. Transmit-and-display (a=T), so it belongs on the CLI/stdout path. Null
/// on empty art.
pub fn renderKitty(arena: std.mem.Allocator, art: []const u8, cols: usize) !?[]const u8 {
    const bmp = try rasterize(arena, art);
    if (bmp.w == 0 or bmp.h == 0) return null;

    const rgb = try arena.alloc(u8, bmp.w * bmp.h * 3);
    for (bmp.px, 0..) |p, i| {
        const v: u8 = if (p != 0) 230 else 0;
        rgb[i * 3] = v;
        rgb[i * 3 + 1] = v;
        rgb[i * 3 + 2] = v;
    }

    const Enc = std.base64.standard.Encoder;
    const b64 = try arena.alloc(u8, Enc.calcSize(rgb.len));
    _ = Enc.encode(b64, rgb);

    var out: std.ArrayList(u8) = .empty;
    const chunk: usize = 4096;
    var off: usize = 0;
    var first = true;
    while (off < b64.len) {
        const end = @min(off + chunk, b64.len);
        const more: u8 = if (end < b64.len) 1 else 0;
        if (first) {
            const hdr = try std.fmt.allocPrint(arena, "\x1b_Gf=24,s={d},v={d},c={d},a=T,m={d};", .{ bmp.w, bmp.h, cols, more });
            try out.appendSlice(arena, hdr);
            first = false;
        } else {
            const hdr = try std.fmt.allocPrint(arena, "\x1b_Gm={d};", .{more});
            try out.appendSlice(arena, hdr);
        }
        try out.appendSlice(arena, b64[off..end]);
        try out.appendSlice(arena, "\x1b\\");
        off = end;
    }
    return out.items;
}

/// Sixel (DCS ... ST), grayscale quantized to 8 levels, scaled to roughly `cols`
/// columns. Null on empty art.
pub fn renderSixel(arena: std.mem.Allocator, art: []const u8, cols: usize) !?[]const u8 {
    const bmp = try rasterize(arena, art);
    if (bmp.w == 0 or bmp.h == 0) return null;

    const tw = @min(bmp.w, @max(cols, 1) * 8);
    const th = @max((bmp.h * tw) / bmp.w, 1);
    const gray = try downscale(arena, bmp, tw, th);

    const levels: usize = 8;
    const idx = try arena.alloc(u8, tw * th);
    for (gray, 0..) |gv, i| idx[i] = @intCast(@min(@as(usize, gv) * levels / 256, levels - 1));

    var out: std.ArrayList(u8) = .empty;
    var buf: [32]u8 = undefined;
    try out.appendSlice(arena, "\x1bPq");
    try out.appendSlice(arena, try std.fmt.bufPrint(&buf, "\"1;1;{d};{d}", .{ tw, th }));
    // Palette: levels 1..N-1 (level 0 stays terminal background).
    var c: usize = 1;
    while (c < levels) : (c += 1) {
        const v = c * 100 / (levels - 1);
        try out.appendSlice(arena, try std.fmt.bufPrint(&buf, "#{d};2;{d};{d};{d}", .{ c, v, v, v }));
    }

    // Sixel draws in horizontal bands of 6 pixel rows. Each byte carries one column
    // of the band, its low 6 bits being the 6 vertical pixels (offset by 0x3f). Within
    // a band every color is stamped in its own left-to-right pass. '$' rewinds to the
    // band start so the next color overlays it, '-' advances to the next band.
    var band: usize = 0;
    while (band * 6 < th) : (band += 1) {
        var color: usize = 1;
        while (color < levels) : (color += 1) {
            // Skip colors absent from this band: an empty pass would emit tw blank
            // bytes for nothing.
            var present = false;
            present: for (0..tw) |x| {
                for (0..6) |row| {
                    const y = band * 6 + row;
                    if (y < th and idx[y * tw + x] == color) {
                        present = true;
                        break :present;
                    }
                }
            }
            if (!present) continue;
            try out.appendSlice(arena, try std.fmt.bufPrint(&buf, "#{d}", .{color}));
            for (0..tw) |x| {
                var mask: u8 = 0;
                for (0..6) |row| {
                    const y = band * 6 + row;
                    if (y < th and idx[y * tw + x] == color) mask |= (@as(u8, 1) << @as(u3, @intCast(row)));
                }
                try out.append(arena, 0x3f + mask);
            }
            try out.append(arena, '$'); // carriage return: overlay next color on this band
        }
        try out.append(arena, '-'); // next band
    }
    try out.appendSlice(arena, "\x1b\\");
    return out.items;
}

pub const Rgba = struct { w: usize, h: usize, px: []u8 };

/// ASCII art to an RGBA buffer (white on transparent), for libvaxis to transmit.
/// The buffer comes from `gpa` and the caller frees it. The temp bitmap uses
/// `arena`. Null on empty art.
pub fn rasterizeRgba(arena: std.mem.Allocator, gpa: std.mem.Allocator, art: []const u8) !?Rgba {
    const bmp = try rasterize(arena, art);
    if (bmp.w == 0 or bmp.h == 0) return null;
    const px = try gpa.alloc(u8, bmp.w * bmp.h * 4);
    for (bmp.px, 0..) |p, i| {
        if (p != 0) {
            px[i * 4] = 230;
            px[i * 4 + 1] = 230;
            px[i * 4 + 2] = 230;
            px[i * 4 + 3] = 255;
        } else {
            px[i * 4] = 0;
            px[i * 4 + 1] = 0;
            px[i * 4 + 2] = 0;
            px[i * 4 + 3] = 0;
        }
    }
    return .{ .w = bmp.w, .h = bmp.h, .px = px };
}

/// Rasterize `art` into a 1-bit bitmap with the embedded 8x8 font: each character
/// occupies an 8x8 cell, so the bitmap is (widestLine*8) x (lineCount*8). Pass 1
/// measures the text grid, pass 2 lights one pixel per set glyph bit. Non-ASCII
/// bytes (>=128) have no glyph and are skipped. Empty art -> zero-sized bitmap.
fn rasterize(arena: std.mem.Allocator, art: []const u8) !Bitmap {
    var rows: usize = 0;
    var cols: usize = 0;
    {
        var it = std.mem.splitScalar(u8, art, '\n');
        while (it.next()) |ln| {
            rows += 1;
            cols = @max(cols, ln.len);
        }
    }
    if (rows == 0 or cols == 0) return .{ .w = 0, .h = 0, .px = &.{} };

    const w = cols * 8;
    const h = rows * 8;
    const px = try arena.alloc(u8, w * h);
    @memset(px, 0);

    var ly: usize = 0;
    var it = std.mem.splitScalar(u8, art, '\n');
    while (it.next()) |ln| : (ly += 1) {
        for (ln, 0..) |ch, cx| {
            if (ch >= 128) continue;
            const glyph = font.glyphs[ch];
            for (glyph, 0..) |bits, row| {
                // Bit `col` (LSB = leftmost pixel) lights column `col` of the 8x8 cell.
                for (0..8) |col| {
                    if (bits & (@as(u8, 1) << @as(u3, @intCast(col))) != 0) {
                        px[(ly * 8 + row) * w + cx * 8 + col] = 1;
                    }
                }
            }
        }
    }
    return .{ .w = w, .h = h, .px = px };
}

/// Box-downscale `bmp` to `tw`x`th`. Each output pixel owns a source rectangle
/// [sx0,sx1) x [sy0,sy1) and takes the average of its 0/1 source pixels, mapped to
/// 0..255, i.e. how covered that cell is (fully set -> 255). The `@max(.., +1)`
/// guards keep every rectangle at least 1x1 so `cnt` is never 0.
fn downscale(arena: std.mem.Allocator, bmp: Bitmap, tw: usize, th: usize) ![]u8 {
    const gray = try arena.alloc(u8, tw * th);
    for (0..th) |oy| {
        const sy0 = oy * bmp.h / th;
        const sy1 = @max((oy + 1) * bmp.h / th, sy0 + 1);
        for (0..tw) |ox| {
            const sx0 = ox * bmp.w / tw;
            const sx1 = @max((ox + 1) * bmp.w / tw, sx0 + 1);
            var sum: usize = 0;
            var cnt: usize = 0;
            var sy = sy0;
            while (sy < sy1 and sy < bmp.h) : (sy += 1) {
                var sx = sx0;
                while (sx < sx1 and sx < bmp.w) : (sx += 1) {
                    sum += bmp.px[sy * bmp.w + sx];
                    cnt += 1;
                }
            }
            gray[oy * tw + ox] = if (cnt > 0) @intCast(sum * 255 / cnt) else 0;
        }
    }
    return gray;
}

test "render produces half-block lines for a glyph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const img = (try render(arena.allocator(), "A", 8)).?;
    try std.testing.expect(std.mem.indexOf(u8, img, "\u{2580}") != null); // upper half block
    try std.testing.expect(std.mem.indexOf(u8, img, "\x1b[38;2;") != null); // truecolor fg
}

test "render returns null on empty art" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try render(arena.allocator(), "", 8)) == null);
}

test "renderKitty emits a graphics escape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const esc = (try renderKitty(arena.allocator(), "A", 4)).?;
    try std.testing.expect(std.mem.startsWith(u8, esc, "\x1b_Gf=24,"));
    try std.testing.expect(std.mem.indexOf(u8, esc, "a=T") != null);
    try std.testing.expect(std.mem.endsWith(u8, esc, "\x1b\\"));
}

test "renderSixel emits a DCS sixel sequence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const esc = (try renderSixel(arena.allocator(), "A", 8)).?;
    try std.testing.expect(std.mem.startsWith(u8, esc, "\x1bPq"));
    try std.testing.expect(std.mem.indexOf(u8, esc, "#1;2;") != null);
    try std.testing.expect(std.mem.endsWith(u8, esc, "\x1b\\"));
}

test "rasterize sizes the bitmap to one 8x8 cell per character" {
    // Widest line drives width, line count drives height: "AB\nC" -> 2x2 cells.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bmp = try rasterize(arena.allocator(), "AB\nC");
    try std.testing.expectEqual(@as(usize, 16), bmp.w);
    try std.testing.expectEqual(@as(usize, 16), bmp.h);
    try std.testing.expectEqual(@as(usize, 16 * 16), bmp.px.len);
}

test "rasterize returns a zero-sized bitmap for empty art" {
    // Nothing to draw must be distinguishable downstream (render* short-circuits on it).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bmp = try rasterize(arena.allocator(), "");
    try std.testing.expectEqual(@as(usize, 0), bmp.w);
    try std.testing.expectEqual(@as(usize, 0), bmp.h);
}

test "rasterize keeps a space glyph fully blank" {
    // A space still owns an 8x8 cell, but its glyph is all zeros: no pixel is set.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bmp = try rasterize(arena.allocator(), " ");
    try std.testing.expectEqual(@as(usize, 8), bmp.w);
    for (bmp.px) |p| try std.testing.expectEqual(@as(u8, 0), p);
}

test "rasterize lights foreground pixels for a visible glyph" {
    // A drawable character must set at least one pixel, else nothing would render.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bmp = try rasterize(arena.allocator(), "A");
    var any = false;
    for (bmp.px) |p| {
        if (p != 0) any = true;
    }
    try std.testing.expect(any);
}

test "rasterize ignores non-ASCII bytes" {
    // The font only covers ASCII. Bytes >= 128 have no glyph and must add no pixels.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bmp = try rasterize(arena.allocator(), &[_]u8{0x80});
    try std.testing.expectEqual(@as(usize, 8), bmp.w);
    for (bmp.px) |p| try std.testing.expectEqual(@as(u8, 0), p);
}

test "downscale averages 0/1 pixels into grayscale coverage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Half-covered cell (one set, one unset pixel) -> ~50% gray: 255*1/2 = 127.
    const half = try a.dupe(u8, &[_]u8{ 1, 0 });
    const g = try downscale(a, .{ .w = 2, .h = 1, .px = half }, 1, 1);
    try std.testing.expectEqual(@as(u8, 127), g[0]);

    // Fully set -> 255, fully clear -> 0, regardless of the box size.
    const full = try a.alloc(u8, 16);
    @memset(full, 1);
    for (try downscale(a, .{ .w = 4, .h = 4, .px = full }, 2, 2)) |v|
        try std.testing.expectEqual(@as(u8, 255), v);

    const clear = try a.alloc(u8, 16);
    @memset(clear, 0);
    for (try downscale(a, .{ .w = 4, .h = 4, .px = clear }, 2, 2)) |v|
        try std.testing.expectEqual(@as(u8, 0), v);
}

test "rasterizeRgba paints set pixels opaque white and clears the rest" {
    // Foreground is white-on-transparent so the terminal composites the diagram
    // over its own background.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rgba = (try rasterizeRgba(arena.allocator(), std.testing.allocator, "A")).?;
    defer std.testing.allocator.free(rgba.px);

    var saw_white = false;
    var saw_clear = false;
    var i: usize = 0;
    while (i < rgba.px.len) : (i += 4) {
        if (rgba.px[i + 3] == 255) {
            saw_white = true;
            try std.testing.expectEqual(@as(u8, 230), rgba.px[i]);
            try std.testing.expectEqual(@as(u8, 230), rgba.px[i + 1]);
            try std.testing.expectEqual(@as(u8, 230), rgba.px[i + 2]);
        } else {
            saw_clear = true;
            try std.testing.expectEqual(@as(u8, 0), rgba.px[i]);
            try std.testing.expectEqual(@as(u8, 0), rgba.px[i + 3]);
        }
    }
    try std.testing.expect(saw_white and saw_clear);
}

test "rasterizeRgba returns null on empty art" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try rasterizeRgba(arena.allocator(), std.testing.allocator, "")) == null);
}
