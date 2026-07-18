//! Search state for the TUI pager: matching, match cursor, prompt buffer.

const std = @import("std");
const render = @import("md");
const ansiseg = render.ansiseg;
const displayWidth = render.displayWidth;

/// An occurrence in a rendered line. `start`/`end` are display columns, like
/// render.LinkSpan, not byte offsets: the pager reverses cells, and a line can
/// hold wide or zero-width graphemes, so byte offsets would mark the wrong ones.
pub const Match = struct { line: usize, start: usize, end: usize };

/// The smartcase trigger: an ASCII uppercase letter makes the search exact.
fn hasUpper(needle: []const u8) bool {
    for (needle) |c| if (std.ascii.isUpper(c)) return true;
    return false;
}

/// Every occurrence of `needle` across `lines`, in document order.
///
/// Matching is smartcase (an all-lowercase needle matches any case, a needle
/// carrying an uppercase letter matches exactly) and runs on each line's plain
/// text, so a match straddling a style boundary is still found. Occurrences
/// never overlap. An empty needle matches nothing.
pub fn findAll(gpa: std.mem.Allocator, lines: []const []const u8, needle: []const u8) ![]Match {
    var out: std.ArrayList(Match) = .empty;
    errdefer out.deinit(gpa);
    // Guard: indexOf of an empty needle keeps returning the same position, so
    // the scan below would never advance.
    if (needle.len == 0) return out.toOwnedSlice(gpa);
    const sensitive = hasUpper(needle);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    for (lines, 0..) |line, ln| {
        _ = arena.reset(.retain_capacity);
        const plain = try ansiseg.stripAnsi(arena.allocator(), line);
        var p: usize = 0;
        while (indexOfFrom(plain, p, needle, sensitive)) |hit| {
            const start = displayWidth(plain[0..hit]);
            try out.append(gpa, .{
                .line = ln,
                .start = start,
                .end = start + displayWidth(plain[hit .. hit + needle.len]),
            });
            p = hit + needle.len; // non-overlapping
        }
    }
    return out.toOwnedSlice(gpa);
}

fn indexOfFrom(haystack: []const u8, start: usize, needle: []const u8, sensitive: bool) ?usize {
    if (sensitive) return std.mem.indexOfPos(u8, haystack, start, needle);
    return std.ascii.indexOfIgnoreCasePos(haystack, start, needle);
}

/// Interactive search state for the loaded document.
///
/// `matches` holds rendered line indices and display columns, both of which
/// depend on the wrap width, so it is rebuilt on resize and cleared when the
/// document changes.
pub const Search = struct {
    /// Live prompt buffer (gpa-owned).
    query: std.ArrayList(u8) = .empty,
    /// gpa-owned, rebuilt whenever the query or the rendered lines change.
    matches: []Match = &.{},
    current: ?usize = null,
    /// The prompt is open: key presses feed `query`, not the pager.
    input: bool = false,
    /// Pager offset to restore when the prompt is cancelled.
    saved_offset: usize = 0,

    pub fn deinit(self: *Search, gpa: std.mem.Allocator) void {
        self.query.deinit(gpa);
        gpa.free(self.matches);
    }

    pub fn clear(self: *Search, gpa: std.mem.Allocator) void {
        self.query.clearRetainingCapacity();
        gpa.free(self.matches);
        self.matches = &.{};
        self.current = null;
    }

    /// Re-runs the query against `lines`. New matches are built before the old ones
    /// are released, so a failure here leaves the state intact, not pointing at
    /// freed memory.
    ///
    /// Re-wrapping can drop a match that now straddles a line break, so the cursor
    /// is clamped, never assumed still valid.
    pub fn rebuild(self: *Search, gpa: std.mem.Allocator, lines: []const []const u8) !void {
        const m = try findAll(gpa, lines, self.query.items);
        gpa.free(self.matches);
        self.matches = m;
        if (m.len == 0) {
            self.current = null;
        } else if (self.current) |c| {
            if (c >= m.len) self.current = m.len - 1;
        }
    }

    /// First match at or after `line`, wrapping to the first when none follows.
    pub fn selectFrom(self: *Search, line: usize) void {
        if (self.matches.len == 0) {
            self.current = null;
            return;
        }
        for (self.matches, 0..) |m, i| {
            if (m.line >= line) {
                self.current = i;
                return;
            }
        }
        self.current = 0; // wrap
    }

    pub fn next(self: *Search) void {
        const n = self.matches.len;
        if (n == 0) return;
        self.current = if (self.current) |c| (c + 1) % n else 0;
    }

    pub fn prev(self: *Search) void {
        const n = self.matches.len;
        if (n == 0) return;
        self.current = if (self.current) |c| (c + n - 1) % n else n - 1;
    }

    pub fn currentLine(self: *const Search) ?usize {
        const c = self.current orelse return null;
        return self.matches[c].line;
    }

    /// Backspace. Pops a whole UTF-8 codepoint, so erasing a multi-byte character
    /// leaves no broken tail for the footer to print.
    pub fn popCodepoint(self: *Search) void {
        var i = self.query.items.len;
        while (i > 0) {
            i -= 1;
            if (self.query.items[i] & 0xc0 != 0x80) break; // not a continuation byte
        }
        self.query.shrinkRetainingCapacity(i);
    }
};

test "findAll matches across style boundaries" {
    const gpa = std.testing.allocator;
    const lines = [_][]const u8{ "\x1b[1mQuick\x1b[0m Start", "body" };
    const m = try findAll(gpa, &lines, "quick start");
    defer gpa.free(m);
    // The match straddles a style boundary: it is only findable once the escapes
    // are stripped, and its columns must ignore the zero-width escapes.
    try std.testing.expectEqual(@as(usize, 1), m.len);
    try std.testing.expectEqual(@as(usize, 0), m[0].line);
    try std.testing.expectEqual(@as(usize, 0), m[0].start);
    try std.testing.expectEqual(@as(usize, 11), m[0].end);
}

test "findAll reports display columns, not byte offsets" {
    const gpa = std.testing.allocator;
    // Wide graphemes before the needle: byte offsets would land the highlight on
    // the wrong cells.
    const lines = [_][]const u8{"世界 hi"}; // 世界 = 4 columns, 6 bytes
    const m = try findAll(gpa, &lines, "hi");
    defer gpa.free(m);
    try std.testing.expectEqual(@as(usize, 1), m.len);
    try std.testing.expectEqual(@as(usize, 5), m[0].start); // 4 + space
    try std.testing.expectEqual(@as(usize, 7), m[0].end);
}

test "findAll spans a wide needle by its display width" {
    const gpa = std.testing.allocator;
    const lines = [_][]const u8{"a 世 b"};
    const m = try findAll(gpa, &lines, "世");
    defer gpa.free(m);
    try std.testing.expectEqual(@as(usize, 1), m.len);
    try std.testing.expectEqual(@as(usize, 2), m[0].start);
    try std.testing.expectEqual(@as(usize, 4), m[0].end); // 2 columns wide
}

test "findAll is smartcase" {
    const gpa = std.testing.allocator;
    const lines = [_][]const u8{ "body", "BODY", "Body" };

    // All-lowercase needle: case-insensitive, so every line matches.
    const lower = try findAll(gpa, &lines, "body");
    defer gpa.free(lower);
    try std.testing.expectEqual(@as(usize, 3), lower.len);

    // An uppercase letter in the needle makes the search exact.
    const mixed = try findAll(gpa, &lines, "Body");
    defer gpa.free(mixed);
    try std.testing.expectEqual(@as(usize, 1), mixed.len);
    try std.testing.expectEqual(@as(usize, 2), mixed[0].line);
}

test "findAll returns every occurrence on a line, non-overlapping" {
    const gpa = std.testing.allocator;
    const lines = [_][]const u8{"aaaa"};
    const m = try findAll(gpa, &lines, "aa");
    defer gpa.free(m);
    // "aa" at 0 and 2, not at 1: a match consumes what it covers.
    try std.testing.expectEqual(@as(usize, 2), m.len);
    try std.testing.expectEqual(@as(usize, 0), m[0].start);
    try std.testing.expectEqual(@as(usize, 2), m[1].start);
}

test "findAll of an empty needle matches nothing" {
    const gpa = std.testing.allocator;
    const lines = [_][]const u8{"anything"};
    const m = try findAll(gpa, &lines, "");
    defer gpa.free(m);
    // Guards the scan loop: an empty needle would otherwise never advance.
    try std.testing.expectEqual(@as(usize, 0), m.len);
}

test "selectFrom picks the first match at or after a line, wrapping" {
    var s: Search = .{};
    var m = [_]Match{
        .{ .line = 2, .start = 0, .end = 1 },
        .{ .line = 9, .start = 0, .end = 1 },
    };
    s.matches = &m;

    s.selectFrom(0);
    try std.testing.expectEqual(@as(?usize, 0), s.current);
    s.selectFrom(3); // past the first match
    try std.testing.expectEqual(@as(?usize, 1), s.current);
    s.selectFrom(9); // "at or after" includes the line itself
    try std.testing.expectEqual(@as(?usize, 1), s.current);
    s.selectFrom(50); // nothing follows: wrap to the top of the document
    try std.testing.expectEqual(@as(?usize, 0), s.current);
}

test "next and prev wrap around the ends" {
    var s: Search = .{};
    var m = [_]Match{
        .{ .line = 1, .start = 0, .end = 1 },
        .{ .line = 2, .start = 0, .end = 1 },
    };
    s.matches = &m;

    s.next(); // no cursor yet: start at the first match
    try std.testing.expectEqual(@as(?usize, 0), s.current);
    s.next();
    try std.testing.expectEqual(@as(?usize, 1), s.current);
    s.next(); // past the last: back to the first
    try std.testing.expectEqual(@as(?usize, 0), s.current);
    s.prev(); // before the first: on to the last
    try std.testing.expectEqual(@as(?usize, 1), s.current);
}

test "next and prev on no matches leave the cursor unset" {
    var s: Search = .{};
    s.next();
    try std.testing.expectEqual(@as(?usize, null), s.current);
    s.prev();
    try std.testing.expectEqual(@as(?usize, null), s.current);
    try std.testing.expectEqual(@as(?usize, null), s.currentLine());
}

test "rebuild clamps a cursor left past the end by re-wrapping" {
    const gpa = std.testing.allocator;
    var s: Search = .{};
    defer s.deinit(gpa);
    try s.query.appendSlice(gpa, "x");

    try s.rebuild(gpa, &[_][]const u8{ "x", "x", "x" });
    s.current = 2;
    // A narrower width drops matches: the cursor must not dangle past the end.
    try s.rebuild(gpa, &[_][]const u8{"x"});
    try std.testing.expectEqual(@as(?usize, 0), s.current);
    // Losing every match drops the cursor entirely.
    try s.rebuild(gpa, &[_][]const u8{"nope"});
    try std.testing.expectEqual(@as(?usize, null), s.current);
}

test "popCodepoint erases whole characters, not bytes" {
    const gpa = std.testing.allocator;
    var s: Search = .{};
    defer s.deinit(gpa);
    try s.query.appendSlice(gpa, "aé"); // é is 2 bytes
    s.popCodepoint();
    // Popping one byte would leave a broken UTF-8 tail for the footer to print.
    try std.testing.expectEqualStrings("a", s.query.items);
    s.popCodepoint();
    try std.testing.expectEqualStrings("", s.query.items);
    s.popCodepoint(); // empty: must not underflow
    try std.testing.expectEqualStrings("", s.query.items);
}
