//! Text helpers shared by the Mermaid renderers: line iteration over a diagram
//! body, display-width clipping, small formatting utilities.

const std = @import("std");
const width = @import("../markdown/width.zig");

pub const ws = " \t\r";

/// `raw` as read, for the indentation-sensitive parsers. `text` is trimmed.
pub const Line = struct { raw: []const u8, text: []const u8 };

/// Skips the header line, blanks and %% comments. Parsers that read the header
/// themselves keep their own loop.
pub const BodyLines = struct {
    it: std.mem.SplitIterator(u8, .scalar),
    first: bool = true,

    pub fn init(src: []const u8) BodyLines {
        return .{ .it = std.mem.splitScalar(u8, src, '\n') };
    }

    pub fn next(self: *BodyLines) ?Line {
        while (self.it.next()) |raw| {
            const t = std.mem.trim(u8, raw, ws);
            if (self.first) {
                self.first = false;
                continue;
            }
            if (t.len == 0 or std.mem.startsWith(u8, t, "%%")) continue;
            return .{ .raw = raw, .text = t };
        }
        return null;
    }
};

/// Counts display columns, cuts on a UTF-8 boundary.
pub fn clip(s: []const u8, max: usize) []const u8 {
    if (width.displayWidth(s) <= max) return s;
    var i: usize = 0;
    var w: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + len, s.len);
        const cw = width.displayWidth(s[i..end]);
        if (w + cw > max) break;
        w += cw;
        i = end;
    }
    return s[0..i];
}

pub fn stripQuotes(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, "\"");
}

pub fn appendSpaces(out: *std.ArrayList(u8), arena: std.mem.Allocator, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try out.append(arena, ' ');
}

/// Whole values print as integers. `frac_fmt` is a parameter because renderers
/// disagree on decimals.
pub fn fmtNum(arena: std.mem.Allocator, v: f64, comptime frac_fmt: []const u8) []const u8 {
    if (v == @floor(v) and @abs(v) < 1e15) {
        return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(v))}) catch "?";
    }
    return std.fmt.allocPrint(arena, frac_fmt, .{v}) catch "?";
}

pub fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

pub fn leadingSpaces(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and (line[n] == ' ' or line[n] == '\t')) : (n += 1) {}
    return n;
}

pub fn firstWord(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, ws);
    const e = std.mem.indexOfAny(u8, t, " \t") orelse t.len;
    return t[0..e];
}

/// The proportional-bar idiom of pie/sankey/treemap. Rounding stays at the call
/// sites, which disagree.
pub fn appendBar(out: *std.ArrayList(u8), arena: std.mem.Allocator, fill: []const u8, filled: usize, total: usize) !void {
    var i: usize = 0;
    while (i < filled) : (i += 1) try out.appendSlice(arena, fill);
    while (i < total) : (i += 1) try out.append(arena, ' ');
}

/// Dense indices for string ids, first-seen order, one T per id (parsers fill the
/// T in afterwards). Maps diagram ids onto node/participant arrays.
pub fn Interner(comptime T: type) type {
    return struct {
        arena: std.mem.Allocator,
        index: std.StringHashMap(usize),
        ids: std.ArrayList([]const u8) = .empty,
        items: std.ArrayList(T) = .empty,

        pub fn init(arena: std.mem.Allocator) @This() {
            return .{ .arena = arena, .index = .init(arena) };
        }

        pub fn ensure(self: *@This(), id: []const u8, default: T) !usize {
            if (self.index.get(id)) |i| return i;
            const i = self.items.items.len;
            try self.index.put(id, i);
            try self.ids.append(self.arena, id);
            try self.items.append(self.arena, default);
            return i;
        }
    };
}

/// Appends one member/attribute line to `id`'s body list, creating the list on
/// first use. Shared by the class/ER and requirement parsers.
pub fn addMember(
    arena: std.mem.Allocator,
    members: *std.StringHashMap(std.ArrayList([]const u8)),
    id: []const u8,
    line: []const u8,
) !void {
    const gop = try members.getOrPut(id);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(arena, line);
}

test "clip cuts on utf-8 boundaries at the display width" {
    try std.testing.expectEqualStrings("abc", clip("abc", 5));
    try std.testing.expectEqualStrings("ab", clip("abcd", 2));
    try std.testing.expectEqualStrings("é", clip("éé", 1));
}

test "BodyLines skips header, blanks and comments; keeps raw indentation" {
    var it = BodyLines.init("kanban\n\n%% note\n  Todo\n");
    const ln = it.next().?;
    try std.testing.expectEqualStrings("Todo", ln.text);
    try std.testing.expectEqualStrings("  Todo", ln.raw);
    try std.testing.expectEqual(@as(?Line, null), it.next());
}

test "firstWord returns the leading token, trimmed" {
    try std.testing.expectEqualStrings("commit", firstWord("  commit id: \"x\""));
    try std.testing.expectEqualStrings("solo", firstWord("solo"));
    try std.testing.expectEqualStrings("", firstWord("   "));
}

test "appendBar fills then pads to the total width" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try appendBar(&out, gpa, "#", 3, 5);
    try std.testing.expectEqualStrings("###  ", out.items);
}

test "Interner assigns first-seen dense indices and keeps defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const V = struct { label: []const u8 };
    var st = Interner(V).init(arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), try st.ensure("a", .{ .label = "a" }));
    try std.testing.expectEqual(@as(usize, 1), try st.ensure("b", .{ .label = "b" }));
    try std.testing.expectEqual(@as(usize, 0), try st.ensure("a", .{ .label = "other" }));
    try std.testing.expectEqualStrings("a", st.items.items[0].label); // first default kept
    try std.testing.expectEqual(@as(usize, 2), st.ids.items.len);
}

test "fmtNum renders whole values as integers, else with the given format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("3", fmtNum(arena.allocator(), 3.0, "{d:.1}"));
    try std.testing.expectEqualStrings("2.5", fmtNum(arena.allocator(), 2.5, "{d:.1}"));
}

test "stripQuotes removes wrapping double quotes only" {
    try std.testing.expectEqualStrings("hi", stripQuotes("\"hi\""));
    try std.testing.expectEqualStrings("hi", stripQuotes("hi"));
}

test "leadingSpaces counts spaces and tabs before the first token" {
    try std.testing.expectEqual(@as(usize, 2), leadingSpaces("  x"));
    try std.testing.expectEqual(@as(usize, 2), leadingSpaces("\t x"));
    try std.testing.expectEqual(@as(usize, 0), leadingSpaces("x"));
}

test "eqIgnoreCase compares case-insensitively and by length" {
    try std.testing.expect(eqIgnoreCase("LR", "lr"));
    try std.testing.expect(!eqIgnoreCase("ab", "abc"));
}

test "addMember appends to a per-id list, creating it on first use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var members: std.StringHashMap(std.ArrayList([]const u8)) = .init(a);
    try addMember(a, &members, "Dog", "+bark()");
    try addMember(a, &members, "Dog", "+fetch()");
    const list = members.get("Dog").?;
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("+bark()", list.items[0]);
    try std.testing.expectEqualStrings("+fetch()", list.items[1]);
}
