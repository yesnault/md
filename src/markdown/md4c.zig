//! Thin binding to the md4c CommonMark + GFM parser (build.zig.zon package).
//!
//! The renderer (ansi_renderer.zig) uses `c.md_parse` with SAX-style callbacks.

pub const c = @cImport({
    @cInclude("md4c.h");
});
