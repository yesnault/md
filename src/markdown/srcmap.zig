//! Maps a 1-based line in the raw Markdown source to the ordinal of the
//! heading whose section contains it, mirroring which headings the ANSI
//! renderer records as anchors (see ansi_renderer.recordAnchor): anchors are
//! appended in document order, so the K-th counted heading here is
//! `anchors.items[K - 1]`.
//!
//! Known approximations (both only misplace a jump locally, never crash):
//! - a multi-line setext paragraph uses its last line as the heading start,
//!   so pointing at an earlier line of that paragraph resolves to the
//!   previous section,
//! - headings nested four or more columns deep inside list items are treated
//!   as indented code.

const std = @import("std");

const Prev = enum { blank, para, other };
const Fence = struct { char: u8, len: usize };

/// K, the number of anchor-producing headings whose start line is <= `line`
/// (1-based). K == 0 means `line` precedes every heading.
pub fn headingOrdinalAt(source: []const u8, line: usize) usize {
    var count: usize = 0;
    var prev: Prev = .blank;
    var fence: ?Fence = null;
    var it = std.mem.splitScalar(u8, source, '\n');
    var i: usize = 0;
    while (it.next()) |raw| {
        i += 1;
        if (i - 1 > line) break; // scan one past `line`: a setext underline
        // at line+1 turns `line` itself into a heading
        var rest = raw;
        while (stripQuoteMarker(rest)) |r| rest = r;
        const indent = leadingIndent(rest);
        const trimmed = std.mem.trim(u8, rest, " \t\r");
        if (fence) |f| {
            if (indent <= 3 and isFenceClose(trimmed, f)) fence = null;
            prev = .other;
            continue;
        }
        if (trimmed.len == 0) {
            prev = .blank;
            continue;
        }
        if (indent >= 4) {
            // indented code, or the lazy continuation of an open paragraph
            if (prev != .para) prev = .other;
            continue;
        }
        if (fenceOpen(trimmed)) |f| {
            fence = f;
            prev = .other;
            continue;
        }
        if (atxContent(trimmed)) |content| {
            // content-less ATX ("#" alone) records no anchor, skip it too
            if (content.len != 0 and i <= line) count += 1;
            prev = .other;
            continue;
        }
        if (prev == .para and isSetextUnderline(trimmed)) {
            count += 1; // heading text is line i-1, <= `line` by the loop bound
            prev = .other;
            continue;
        }
        prev = classify(trimmed);
    }
    return count;
}

/// Consumes one blockquote marker (up to 3 spaces, '>', one optional space). Null
/// when the line does not start with one.
fn stripQuoteMarker(s: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < s.len and i < 3 and s[i] == ' ') i += 1;
    if (i >= s.len or s[i] != '>') return null;
    i += 1;
    if (i < s.len and s[i] == ' ') i += 1;
    return s[i..];
}

fn leadingIndent(s: []const u8) usize {
    var col: usize = 0;
    for (s) |c| switch (c) {
        ' ' => col += 1,
        '\t' => col += 4 - (col % 4),
        else => break,
    };
    return col;
}

fn fenceOpen(trimmed: []const u8) ?Fence {
    if (trimmed.len == 0) return null;
    const c = trimmed[0];
    if (c != '`' and c != '~') return null;
    var n: usize = 0;
    while (n < trimmed.len and trimmed[n] == c) n += 1;
    if (n < 3) return null;
    // a backtick fence's info string cannot contain a backtick
    if (c == '`' and std.mem.indexOfScalar(u8, trimmed[n..], '`') != null) return null;
    return .{ .char = c, .len = n };
}

fn isFenceClose(trimmed: []const u8, f: Fence) bool {
    if (trimmed.len < f.len) return false;
    for (trimmed) |c| if (c != f.char) return false;
    return true;
}

/// The heading text of an ATX line ("" when it has none), null when the line is not
/// an ATX heading. The GFM dialect md4c runs with requires a space/tab (or EOL)
/// after the '#' run.
fn atxContent(trimmed: []const u8) ?[]const u8 {
    var n: usize = 0;
    while (n < trimmed.len and trimmed[n] == '#') n += 1;
    if (n == 0 or n > 6) return null;
    if (n < trimmed.len and trimmed[n] != ' ' and trimmed[n] != '\t') return null;
    var content = std.mem.trim(u8, trimmed[n..], " \t");
    var e = content.len;
    while (e > 0 and content[e - 1] == '#') e -= 1;
    if (e == 0) return ""; // content is only a closing '#' run
    // a closing run only counts when preceded by a space or tab
    if (e < content.len and (content[e - 1] == ' ' or content[e - 1] == '\t'))
        content = std.mem.trimEnd(u8, content[0..e], " \t");
    return content;
}

fn isSetextUnderline(trimmed: []const u8) bool {
    if (trimmed.len == 0) return false;
    const c = trimmed[0];
    if (c != '=' and c != '-') return false;
    for (trimmed) |ch| if (ch != c) return false;
    return true;
}

/// List items and thematic breaks cannot carry a setext underline. Everything else
/// is a paragraph.
fn classify(trimmed: []const u8) Prev {
    if (isThematicBreak(trimmed)) return .other;
    if (isBullet(trimmed)) return .other;
    if (isOrderedMarker(trimmed)) return .other;
    return .para;
}

fn isThematicBreak(trimmed: []const u8) bool {
    var mark: u8 = 0;
    var n: usize = 0;
    for (trimmed) |c| {
        if (c == ' ' or c == '\t') continue;
        if (c != '*' and c != '-' and c != '_') return false;
        if (mark == 0) {
            mark = c;
        } else if (c != mark) return false;
        n += 1;
    }
    return n >= 3;
}

fn isBullet(trimmed: []const u8) bool {
    if (trimmed[0] != '-' and trimmed[0] != '+' and trimmed[0] != '*') return false;
    return trimmed.len == 1 or trimmed[1] == ' ' or trimmed[1] == '\t';
}

fn isOrderedMarker(trimmed: []const u8) bool {
    var n: usize = 0;
    while (n < trimmed.len and std.ascii.isDigit(trimmed[n])) n += 1;
    if (n == 0 or n > 9 or n >= trimmed.len) return false;
    if (trimmed[n] != '.' and trimmed[n] != ')') return false;
    return n + 1 == trimmed.len or trimmed[n + 1] == ' ' or trimmed[n + 1] == '\t';
}

const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "headingOrdinalAt: ATX ordinals and boundaries" {
    const src = "intro\n\n# One\n\nbody\n\n## Two\n\ntail\n";
    try expectEqual(@as(usize, 0), headingOrdinalAt(src, 1));
    try expectEqual(@as(usize, 0), headingOrdinalAt(src, 2));
    try expectEqual(@as(usize, 1), headingOrdinalAt(src, 3));
    try expectEqual(@as(usize, 1), headingOrdinalAt(src, 5));
    try expectEqual(@as(usize, 2), headingOrdinalAt(src, 7));
    try expectEqual(@as(usize, 2), headingOrdinalAt(src, 100));
}

test "headingOrdinalAt: fences hide fake headings" {
    const src = "# Real\n\n```\n# fake\n```\n\n~~~\n# fake2\n~~~\n\n## Next\n";
    try expectEqual(@as(usize, 1), headingOrdinalAt(src, 4));
    try expectEqual(@as(usize, 1), headingOrdinalAt(src, 8));
    try expectEqual(@as(usize, 2), headingOrdinalAt(src, 11));
}

test "headingOrdinalAt: setext headings vs thematic breaks" {
    const src = "Title\n=====\n\nbody\n\nSub\n---\n\ntext\n\n---\n";
    try expectEqual(@as(usize, 1), headingOrdinalAt(src, 1));
    try expectEqual(@as(usize, 1), headingOrdinalAt(src, 4));
    try expectEqual(@as(usize, 2), headingOrdinalAt(src, 6));
    try expectEqual(@as(usize, 2), headingOrdinalAt(src, 7));
    try expectEqual(@as(usize, 2), headingOrdinalAt(src, 11)); // break, not a heading
}

test "headingOrdinalAt: anchor parity details" {
    try expectEqual(@as(usize, 0), headingOrdinalAt("#\n", 1)); // no anchor recorded
    try expectEqual(@as(usize, 1), headingOrdinalAt("## x ##\n", 1));
    try expectEqual(@as(usize, 0), headingOrdinalAt("## ##\n", 1)); // empty after closing run
    try expectEqual(@as(usize, 1), headingOrdinalAt("> # quoted\n", 1));
    try expectEqual(@as(usize, 0), headingOrdinalAt("    # code\n", 1));
    try expectEqual(@as(usize, 0), headingOrdinalAt("#nospace\n", 1)); // GFM: space required
}

test "headingOrdinalAt: parity with renderer anchors on a mixed fixture" {
    const renderer = @import("ansi_renderer.zig");
    const theme = @import("../theme.zig");
    const gpa = std.testing.allocator;
    const fixture =
        "# Title\n\nbody\n\nSetext\n======\n\n```\n# fake heading\n```\n\n" ++
        "> ## Quoted\n\n#\n\nlist:\n\n- item\n---\n\n## Real ##\n";
    var anchors: std.ArrayList(renderer.Anchor) = .empty;
    defer {
        for (anchors.items) |a| gpa.free(a.slug);
        anchors.deinit(gpa);
    }
    const out = try renderer.render(gpa, fixture, .{ .width = 80, .theme = theme.notty, .anchors = &anchors });
    defer gpa.free(out);
    try expectEqual(anchors.items.len, headingOrdinalAt(fixture, std.math.maxInt(usize)));
}

test "stripQuoteMarker: consumes one marker only" {
    try expectEqualStrings("x", stripQuoteMarker("> x").?);
    try expectEqualStrings("x", stripQuoteMarker(">x").?);
    try expectEqualStrings("", stripQuoteMarker(">").?);
    try expectEqualStrings("> x", stripQuoteMarker(">> x").?); // nesting peels one level
    try expectEqualStrings("x", stripQuoteMarker("   > x").?);
    try expect(stripQuoteMarker("    > x") == null); // 4 spaces already reads as code
    try expect(stripQuoteMarker("no quote") == null);
}

test "leadingIndent: tabs advance to the next stop of four" {
    try expectEqual(@as(usize, 3), leadingIndent("   x"));
    try expectEqual(@as(usize, 4), leadingIndent("\tx"));
    try expectEqual(@as(usize, 4), leadingIndent(" \tx"));
    try expectEqual(@as(usize, 4), leadingIndent("  \tx"));
    try expectEqual(@as(usize, 0), leadingIndent("x"));
    try expectEqual(@as(usize, 0), leadingIndent(""));
}

test "fenceOpen: length, char and backtick info-string rules" {
    try expect(fenceOpen("``") == null);
    try expectEqual(Fence{ .char = '`', .len = 3 }, fenceOpen("```").?);
    try expectEqual(Fence{ .char = '~', .len = 3 }, fenceOpen("~~~").?);
    try expectEqual(Fence{ .char = '`', .len = 4 }, fenceOpen("````").?);
    try expect(fenceOpen("```js`") == null); // a backtick fence's info string can't hold a backtick
    try expectEqual(Fence{ .char = '~', .len = 3 }, fenceOpen("~~~`").?); // a tilde fence can
    try expect(fenceOpen("xyz") == null);
    try expect(fenceOpen("") == null);
}

test "isFenceClose: same char, at least as long" {
    const f = Fence{ .char = '`', .len = 3 };
    try expect(!isFenceClose("``", f));
    try expect(isFenceClose("```", f));
    try expect(isFenceClose("````", f)); // a longer run of the same char still closes
    try expect(!isFenceClose("~~~", f));
    try expect(!isFenceClose("```x", f));
}

test "atxContent: closing runs and the GFM space rule" {
    try expectEqualStrings("x", atxContent("# x").?);
    try expectEqualStrings("x", atxContent("## x ##").?);
    try expectEqualStrings("", atxContent("#").?);
    try expectEqualStrings("", atxContent("## ##").?); // nothing but a closing run
    try expect(atxContent("#nospace") == null); // GFM: space required after the '#' run
    try expect(atxContent("####### x") == null); // seven '#' is past the depth limit
}

test "isSetextUnderline: uniform '=' or '-' run" {
    try expect(isSetextUnderline("==="));
    try expect(isSetextUnderline("---"));
    try expect(isSetextUnderline("=")); // one character is enough
    try expect(!isSetextUnderline("-=-"));
    try expect(!isSetextUnderline("abc"));
    try expect(!isSetextUnderline(""));
}

test "isThematicBreak: three or more of one mark, spaces allowed" {
    try expect(isThematicBreak("---"));
    try expect(isThematicBreak("***"));
    try expect(isThematicBreak("___"));
    try expect(isThematicBreak("- - -")); // spaces between the marks are ignored
    try expect(!isThematicBreak("--"));
    try expect(!isThematicBreak("-*-"));
    try expect(!isThematicBreak(""));
}

test "isBullet: marker followed by space, tab or end of line" {
    // the scan skips blank lines, so this is never handed an empty string
    try expect(isBullet("- x"));
    try expect(isBullet("+ x"));
    try expect(isBullet("* x"));
    try expect(isBullet("-")); // a bare marker on its own line still counts
    try expect(!isBullet("*emph*")); // no space after the marker
    try expect(!isBullet("abc"));
}

test "isOrderedMarker: 1-9 digits then '.' or ')'" {
    try expect(isOrderedMarker("1. x"));
    try expect(isOrderedMarker("1) x"));
    try expect(isOrderedMarker("1."));
    try expect(!isOrderedMarker("1234567890.")); // ten digits is over the limit
    try expect(!isOrderedMarker("1"));
    try expect(!isOrderedMarker("1.x")); // the delimiter needs a space after it
    try expect(!isOrderedMarker(""));
}

test "classify: list markers and breaks are .other, prose is .para" {
    // reached only on non-empty trimmed lines, same as isBullet
    try expectEqual(Prev.other, classify("---"));
    try expectEqual(Prev.other, classify("- x"));
    try expectEqual(Prev.other, classify("1. x"));
    try expectEqual(Prev.para, classify("hello"));
}
