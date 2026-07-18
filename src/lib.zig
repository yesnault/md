//! Public library surface: Markdown to styled ANSI.
//!
//! Consumers depend on the "md" module (see build.zig) and call renderToAnsi.
//! ansiseg bridges the rendered ANSI to libvaxis cells for TUI embedding.

pub const render = @import("render.zig");
pub const renderToAnsi = render.renderToAnsi;
pub const renderToAnsiCollect = render.renderToAnsiCollect;
pub const Placement = render.Placement;
pub const Anchor = render.Anchor;
pub const LinkSpan = render.LinkSpan;
pub const LinkTable = render.LinkTable;
pub const Collect = render.Collect;

pub const headingOrdinalAt = @import("markdown/srcmap.zig").headingOrdinalAt;
pub const displayWidth = @import("markdown/width.zig").displayWidth;

pub const options = @import("options.zig");
pub const Options = options.Options;

pub const theme = @import("theme.zig");
pub const ansiseg = @import("ansiseg.zig");

test {
    _ = @import("options.zig");
    _ = @import("theme.zig");
    _ = @import("render.zig");
    _ = @import("markdown/width.zig");
    _ = @import("markdown/slug.zig");
    _ = @import("markdown/srcmap.zig");
    _ = @import("markdown/ansi_renderer.zig");
    _ = @import("ansiseg.zig");
    _ = @import("highlight/highlighter.zig");
    _ = @import("mermaid/mermaid.zig");
    _ = @import("mermaid/canvas.zig");
    _ = @import("mermaid/text.zig");
    _ = @import("mermaid/flowchart.zig");
    _ = @import("mermaid/sequence.zig");
    _ = @import("mermaid/pie.zig");
    _ = @import("mermaid/class.zig");
    _ = @import("mermaid/requirement.zig");
    _ = @import("image/image.zig");
    _ = @import("expected_test.zig");
}
