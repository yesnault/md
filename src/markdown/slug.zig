//! GitHub-style heading slugs ("## Quick start" -> "quick-start").

const std = @import("std");

/// Lowercases ASCII letters, keeps alphanumerics, '-' and '_', maps spaces to '-',
/// drops other ASCII punctuation, keeps non-ASCII bytes verbatim. That last part is
/// only an approximation of GitHub's Unicode handling.
pub fn slugify(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (text) |ch| {
        switch (ch) {
            'a'...'z', '0'...'9', '-', '_' => try out.append(alloc, ch),
            'A'...'Z' => try out.append(alloc, ch | 0x20),
            ' ' => try out.append(alloc, '-'),
            else => if (ch >= 0x80) try out.append(alloc, ch),
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Deduplicates slugs across a document: "foo", "foo-1", "foo-2".
pub const Slugger = struct {
    counts: std.StringHashMapUnmanaged(u32) = .empty,

    /// The deduplicated anchor for `text`. Result and internal map keys both come
    /// from `alloc`, so pass an arena.
    pub fn slug(self: *Slugger, alloc: std.mem.Allocator, text: []const u8) ![]u8 {
        const base = try slugify(alloc, text);
        const gop = try self.counts.getOrPut(alloc, base);
        if (!gop.found_existing) {
            gop.value_ptr.* = 0;
            return base;
        }
        gop.value_ptr.* += 1;
        return std.fmt.allocPrint(alloc, "{s}-{d}", .{ base, gop.value_ptr.* });
    }
};

test "slugify lowercases, joins with dashes and drops punctuation" {
    const gpa = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "Quick start", "quick-start" },
        .{ "C++ & Zig!", "c--zig" },
        .{ "keep_under-score", "keep_under-score" },
        .{ "Caf\u{00e9} au lait", "caf\u{00e9}-au-lait" },
    };
    for (cases) |case| {
        const s = try slugify(gpa, case[0]);
        defer gpa.free(s);
        try std.testing.expectEqualStrings(case[1], s);
    }
}

test "Slugger deduplicates repeated headings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var sl: Slugger = .{};
    try std.testing.expectEqualStrings("foo", try sl.slug(alloc, "Foo"));
    try std.testing.expectEqualStrings("foo-1", try sl.slug(alloc, "Foo"));
    try std.testing.expectEqualStrings("foo-2", try sl.slug(alloc, "foo"));
}
