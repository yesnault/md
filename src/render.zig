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
    return ansi.render(gpa, markdown, ansiOpts(opts, .{}));
}

/// Like renderToAnsi, but also fills the side-channel tables selected in `collect`
/// for the TUI: diagram placements, heading anchors, link cells.
pub fn renderToAnsiCollect(
    gpa: std.mem.Allocator,
    markdown: []const u8,
    opts: options.Options,
    collect: Collect,
) ![]u8 {
    return ansi.render(gpa, markdown, ansiOpts(opts, collect));
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
