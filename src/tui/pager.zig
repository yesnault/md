//! Scrollable viewport state for the TUI pager

const std = @import("std");

pub const Pager = struct {
    /// Rendered lines (slices into the owned content buffer held by the caller).
    lines: [][]const u8,
    offset: usize = 0,

    /// Drops the single trailing empty line left by the final newline. The
    /// returned Pager owns `lines`.
    pub fn init(gpa: std.mem.Allocator, content: []const u8) !Pager {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(gpa);
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |ln| try list.append(gpa, ln);
        if (list.items.len > 0 and list.items[list.items.len - 1].len == 0) _ = list.pop();
        return .{ .lines = try list.toOwnedSlice(gpa) };
    }

    pub fn deinit(self: *Pager, gpa: std.mem.Allocator) void {
        gpa.free(self.lines);
    }

    pub fn maxOffset(self: Pager, body_h: usize) usize {
        if (self.lines.len <= body_h) return 0;
        return self.lines.len - body_h;
    }

    pub fn clamp(self: *Pager, body_h: usize) void {
        self.offset = @min(self.offset, self.maxOffset(body_h));
    }

    pub fn scrollBy(self: *Pager, delta: isize, body_h: usize) void {
        const max = self.maxOffset(body_h);
        if (delta < 0) {
            const d: usize = @intCast(-delta);
            self.offset = if (d >= self.offset) 0 else self.offset - d;
        } else {
            self.offset = @min(self.offset + @as(usize, @intCast(delta)), max);
        }
    }

    pub fn toStart(self: *Pager) void {
        self.offset = 0;
    }

    pub fn toEnd(self: *Pager, body_h: usize) void {
        self.offset = self.maxOffset(body_h);
    }

    pub fn scrollTo(self: *Pager, line: usize, body_h: usize) void {
        self.offset = @min(line, self.maxOffset(body_h));
    }

    /// 0..100, and 100 when everything fits.
    pub fn percent(self: Pager, body_h: usize) u8 {
        const max = self.maxOffset(body_h);
        if (max == 0) return 100;
        return @intCast(self.offset * 100 / max);
    }
};

test "init splits lines and drops trailing newline" {
    const gpa = std.testing.allocator;
    var p = try Pager.init(gpa, "a\nb\nc\n");
    defer p.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), p.lines.len);
    try std.testing.expectEqualStrings("a", p.lines[0]);
    try std.testing.expectEqualStrings("c", p.lines[2]);
}

test "scroll clamps to bounds and percent tracks position" {
    const gpa = std.testing.allocator;
    var p = try Pager.init(gpa, "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n");
    defer p.deinit(gpa);
    const body_h: usize = 4; // max offset = 10 - 4 = 6
    try std.testing.expectEqual(@as(usize, 6), p.maxOffset(body_h));

    p.scrollBy(-3, body_h); // already at 0
    try std.testing.expectEqual(@as(usize, 0), p.offset);
    try std.testing.expectEqual(@as(u8, 0), p.percent(body_h));

    p.scrollBy(100, body_h); // clamps to max
    try std.testing.expectEqual(@as(usize, 6), p.offset);
    try std.testing.expectEqual(@as(u8, 100), p.percent(body_h));

    p.toStart();
    p.scrollBy(3, body_h);
    try std.testing.expectEqual(@as(usize, 3), p.offset);
    try std.testing.expectEqual(@as(u8, 50), p.percent(body_h));
}

test "scrollTo puts the line on top and clamps to maxOffset" {
    const gpa = std.testing.allocator;
    var p = try Pager.init(gpa, "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n");
    defer p.deinit(gpa);
    const body_h: usize = 4; // max offset = 10 - 4 = 6
    p.scrollTo(3, body_h);
    try std.testing.expectEqual(@as(usize, 3), p.offset);
    p.scrollTo(9, body_h); // near the end: clamps so the viewport stays full
    try std.testing.expectEqual(@as(usize, 6), p.offset);
}

test "everything fits: max offset zero, percent 100" {
    const gpa = std.testing.allocator;
    var p = try Pager.init(gpa, "a\nb\n");
    defer p.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), p.maxOffset(10));
    try std.testing.expectEqual(@as(u8, 100), p.percent(10));
}
