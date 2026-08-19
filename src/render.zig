//! Renders a Markdown document to styled ANSI: resolves width + theme, then
//! delegates to the Markdown/ANSI renderer. Mermaid blocks are intercepted inside
//! that renderer.

const std = @import("std");
const ansi = @import("markdown/ansi_renderer.zig");
const theme = @import("theme.zig");
const options = @import("options.zig");

pub const Placement = ansi.Placement;
pub const Anchor = ansi.Anchor;
pub const LinkSpan = ansi.LinkSpan;
pub const LinkTable = ansi.LinkTable;

/// Which side-channel tables a TUI render should fill.
pub const Collect = struct {
    /// Mermaid diagrams are emitted as text art (reserving layout space) and a
    /// Placement (with RGBA pixels) is appended per diagram for the pager.
    placements: ?*std.ArrayList(Placement) = null,
    /// One {line, slug} Anchor per heading (GitHub-style slugs).
    anchors: ?*std.ArrayList(Anchor) = null,
    /// Every link's URL and the display cells it occupies.
    links: ?*LinkTable = null,
};

/// Markdown to styled ANSI. A width of 0 is resolved from the terminal. Caller owns
/// the result.
pub fn renderToAnsi(gpa: std.mem.Allocator, markdown: []const u8, opts: options.Options) ![]u8 {
    const clean = try sanitize(gpa, markdown);
    defer if (clean) |c| gpa.free(c);
    return ansi.render(gpa, clean orelse markdown, ansiOpts(opts, .{}));
}

/// Like renderToAnsi, but also fills the side-channel tables selected in `collect`
/// for the TUI: diagram placements, heading anchors, link cells.
pub fn renderToAnsiCollect(
    gpa: std.mem.Allocator,
    markdown: []const u8,
    opts: options.Options,
    collect: Collect,
) ![]u8 {
    const clean = try sanitize(gpa, markdown);
    defer if (clean) |c| gpa.free(c);
    return ansi.render(gpa, clean orelse markdown, ansiOpts(opts, collect));
}

/// Stands in for a control byte the terminal must never see.
const replacement = '?';

/// A document is untrusted input. Left alone, an escape sequence in one reaches
/// the terminal, where OSC 52 writes the system clipboard.
///
/// The sweep runs on the whole buffer: every path out of the renderer draws
/// from it, down to the link URLs the TUI hands to xdg-open.
///
/// Returns null when the document is already clean. That is the usual case and
/// it saves the copy. Otherwise the caller owns the result.
fn sanitize(gpa: std.mem.Allocator, markdown: []const u8) !?[]u8 {
    const first = for (markdown, 0..) |b, i| {
        if (isControl(b)) break i;
    } else return null;
    const out = try gpa.dupe(u8, markdown);
    // One byte in, one byte out: srcmap and --goto-line index into this buffer
    // by offset.
    for (out[first..]) |*b| {
        if (isControl(b.*)) b.* = replacement;
    }
    return out;
}

/// Tab, newline and carriage return are the ones Markdown uses. C1 (0x80-0x9F)
/// is left alone: those bytes only ever appear as UTF-8 continuations.
fn isControl(b: u8) bool {
    return switch (b) {
        // The gaps are 0x09 \t, 0x0a \n and 0x0d \r.
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => true,
        else => false,
    };
}

test "sanitize leaves a clean document uncopied" {
    try std.testing.expectEqual(@as(?[]u8, null), try sanitize(std.testing.allocator, "# hi\n\n\ttab\r\n"));
}

test "sanitize replaces OSC escapes" {
    const gpa = std.testing.allocator;
    // OSC 0 sets the terminal title, OSC 52 writes the system clipboard.
    const doc = "a\x1b]0;PWNED\x07b\x1b]52;c;cm0K\x07c";
    const out = (try sanitize(gpa, doc)).?;
    defer gpa.free(out);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, out, 0x1b));
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, out, 0x07));
    try std.testing.expectEqualStrings("a?]0;PWNED?b?]52;c;cm0K?c", out);
}

test "sanitize preserves length and line count" {
    const gpa = std.testing.allocator;
    const doc = "line1\x1bx\nline2\x00y\nline3";
    const out = (try sanitize(gpa, doc)).?;
    defer gpa.free(out);
    try std.testing.expectEqual(doc.len, out.len);
    try std.testing.expectEqual(
        std.mem.count(u8, doc, "\n"),
        std.mem.count(u8, out, "\n"),
    );
    try std.testing.expectEqualStrings("line1?x\nline2?y\nline3", out);
}

test "sanitize leaves multi-byte UTF-8 alone" {
    const gpa = std.testing.allocator;
    const doc = "é € 😀 ─ ✓";
    try std.testing.expectEqual(@as(?[]u8, null), try sanitize(gpa, doc));
}

fn ansiOpts(opts: options.Options, collect: Collect) ansi.Options {
    var w = opts.width;
    if (w == 0) w = options.detectWidth();
    return .{
        .width = w,
        .theme = opts.theme orelse theme.byName(opts.style),
        .ascii = opts.ascii,
        .graph_dir = opts.graph_dir,
        .image = opts.image,
        .protocol = opts.protocol,
        .placements = collect.placements,
        .anchors = collect.anchors,
        .links = collect.links,
        .wikilinks = opts.wikilinks,
        .wikilink_check = opts.wikilink_check,
    };
}
