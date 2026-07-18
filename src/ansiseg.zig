//! Bridge between the Markdown renderer (which emits an ANSI string) and libvaxis
//! (which draws styled cells). The renderer encodes style inside the text, vaxis
//! wants it beside the text, so this reads the escapes back out.
//!
//! Only the SGR codes the renderer emits are understood, anything else is dropped:
//! reset(0), bold(1), dim(2), italic(3), underline(4), strikethrough(9), plus
//! 256-color (38;5;n) and truecolor (38;2;r;g;b). Both colour forms also apply to
//! the background (48;5;n, 48;2;r;g;b), which half-block images rely on:
//! image.render packs the lower pixel of each cell into its background.

const std = @import("std");
const vaxis = @import("vaxis");

/// `line` must outlive the segments: their text points into it, never a copy.
/// Only the Segment array is allocated.
pub fn lineToSegments(arena: std.mem.Allocator, line: []const u8) ![]vaxis.Segment {
    var segs: std.ArrayList(vaxis.Segment) = .empty;
    var style: vaxis.Style = .{};
    var i: usize = 0;
    var run_start: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
            if (i > run_start) try segs.append(arena, .{ .text = line[run_start..i], .style = style });
            var j = i + 2;
            while (j < line.len and line[j] != 'm') : (j += 1) {}
            if (j >= line.len) {
                i = line.len; // malformed: stop scanning escapes
                run_start = i;
                break;
            }
            applyParams(&style, line[i + 2 .. j]);
            i = j + 1;
            run_start = i;
        } else i += 1;
    }
    if (run_start < line.len) try segs.append(arena, .{ .text = line[run_start..], .style = style });
    return segs.toOwnedSlice(arena);
}

/// `line` as arena-owned plain text, SGR escapes dropped.
///
/// Search runs on this and not on lineToSegments output: a match can straddle a
/// style boundary, and split segments would miss it.
pub fn stripAnsi(arena: std.mem.Allocator, line: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var run_start: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
            if (i > run_start) try out.appendSlice(arena, line[run_start..i]);
            var j = i + 2;
            while (j < line.len and line[j] != 'm') : (j += 1) {}
            if (j >= line.len) {
                i = line.len; // malformed: drop the trailing escape
                run_start = i;
                break;
            }
            i = j + 1;
            run_start = i;
        } else i += 1;
    }
    if (run_start < line.len) try out.appendSlice(arena, line[run_start..]);
    return out.toOwnedSlice(arena);
}

fn applyParams(style: *vaxis.Style, body: []const u8) void {
    if (body.len == 0) {
        style.* = .{};
        return;
    }
    var params: [16]u16 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, body, ';');
    while (it.next()) |p| {
        if (n >= params.len) break;
        params[n] = std.fmt.parseInt(u16, p, 10) catch 0;
        n += 1;
    }
    var k: usize = 0;
    while (k < n) : (k += 1) {
        switch (params[k]) {
            0 => style.* = .{},
            1 => style.bold = true,
            2 => style.dim = true,
            3 => style.italic = true,
            4 => style.ul_style = .single,
            9 => style.strikethrough = true,
            38 => {
                if (k + 2 < n and params[k + 1] == 5) {
                    style.fg = .{ .index = @intCast(params[k + 2]) };
                    k += 2;
                } else if (k + 4 < n and params[k + 1] == 2) {
                    style.fg = .{ .rgb = .{ @intCast(params[k + 2]), @intCast(params[k + 3]), @intCast(params[k + 4]) } };
                    k += 4;
                }
            },
            48 => {
                if (k + 2 < n and params[k + 1] == 5) {
                    style.bg = .{ .index = @intCast(params[k + 2]) };
                    k += 2;
                } else if (k + 4 < n and params[k + 1] == 2) {
                    style.bg = .{ .rgb = .{ @intCast(params[k + 2]), @intCast(params[k + 3]), @intCast(params[k + 4]) } };
                    k += 4;
                }
            },
            else => {},
        }
    }
}

test "lineToSegments splits styled and plain runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const segs = try lineToSegments(arena.allocator(), "\x1b[1mbold\x1b[0m plain");
    try std.testing.expectEqual(@as(usize, 2), segs.len);
    try std.testing.expectEqualStrings("bold", segs[0].text);
    try std.testing.expect(segs[0].style.bold);
    try std.testing.expectEqualStrings(" plain", segs[1].text);
    try std.testing.expect(!segs[1].style.bold);
}

test "lineToSegments parses 256-color foreground" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const segs = try lineToSegments(arena.allocator(), "\x1b[38;5;39mx\x1b[0m");
    try std.testing.expectEqual(@as(usize, 1), segs.len);
    try std.testing.expectEqual(vaxis.Cell.Color{ .index = 39 }, segs[0].style.fg);
}

test "stripAnsi removes escapes and keeps plain text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("bold plain", try stripAnsi(a, "\x1b[1mbold\x1b[0m plain"));
    try std.testing.expectEqualStrings("x", try stripAnsi(a, "\x1b[38;5;39mx\x1b[0m"));
    try std.testing.expectEqualStrings("no escapes", try stripAnsi(a, "no escapes"));
    // malformed trailing escape is dropped, mirroring lineToSegments
    try std.testing.expectEqualStrings("ok", try stripAnsi(a, "ok\x1b[1"));
}
