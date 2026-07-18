//! Markdown → styled ANSI renderer.
//!
//! Drives md4c with SAX callbacks and lays the result out for a terminal: wrapped
//! inline content, indented lists and blockquotes, fenced code with tree-sitter
//! highlighting, rules, GFM tables.

const std = @import("std");
const md = @import("md4c.zig");
const c = md.c;
const theme = @import("../theme.zig");
const width = @import("width.zig");
const registry = @import("../highlight/registry.zig");
const highlighter = @import("../highlight/highlighter.zig");
const mermaid = @import("../mermaid/mermaid.zig");
const image = @import("../image/image.zig");
const options = @import("../options.zig");
const slug = @import("slug.zig");

const Style = theme.Style;
const Theme = theme.Theme;

pub const Options = struct {
    width: u16,
    theme: Theme,
    ascii: bool = false,
    graph_dir: []const u8 = "",
    /// Mermaid diagrams render as images, not text art.
    image: bool = false,
    protocol: options.Protocol = .halfblocks,
    /// When set, Mermaid diagrams are emitted as text art (for layout) and a
    /// Placement (with RGBA pixels) is recorded so the TUI can overlay an image.
    placements: ?*std.ArrayList(Placement) = null,
    /// Wikilinks become links. Off, they stay literal text.
    wikilinks: bool = false,
    /// Unresolvable targets get the wikilink_broken style.
    wikilink_check: ?options.WikilinkCheck = null,
    /// When set, records a {line, slug} Anchor per heading (GitHub-style slugs).
    anchors: ?*std.ArrayList(Anchor) = null,
    /// When set, records each link's URL and the display cells it occupies.
    links: ?*LinkTable = null,
};

/// Locates a diagram in the rendered output and carries its rasterized RGBA pixels,
/// so the TUI can draw it over the reserved text rows.
pub const Placement = struct {
    line: usize, // 0-based line index where the diagram art begins
    rows: u16, // text rows the art occupies
    cols: u16, // text columns the art occupies
    x: u16, // left indent in cells
    w: usize, // pixel width
    h: usize, // pixel height
    rgba: []u8, // gpa-owned RGBA pixels
};

pub const Anchor = struct {
    line: usize, // 0-based first rendered line of the heading
    slug: []u8, // gpa-owned
};

/// One run of display cells a link occupies on one rendered line. A wrapped link
/// produces several.
pub const LinkSpan = struct {
    link: u32, // index into LinkTable.urls
    line: usize, // 0-based rendered line
    start: usize, // first display column
    end: usize, // one past the last display column
};

/// Every hyperlink's URL and the display cells it occupies, document order. Spans
/// come out sorted by line then column, by construction.
pub const LinkTable = struct {
    urls: std.ArrayList([]u8) = .empty, // gpa-owned URL per link
    spans: std.ArrayList(LinkSpan) = .empty,

    pub fn deinit(self: *LinkTable, gpa: std.mem.Allocator) void {
        for (self.urls.items) |u| gpa.free(u);
        self.urls.deinit(gpa);
        self.spans.deinit(gpa);
    }

    /// Extends the last span when it continues the same link on the same line,
    /// bridging the single joining space.
    fn addSpan(self: *LinkTable, gpa: std.mem.Allocator, link: u32, line: usize, start: usize, end: usize) !void {
        if (self.spans.items.len > 0) {
            const last = &self.spans.items[self.spans.items.len - 1];
            if (last.link == link and last.line == line) {
                last.end = end;
                return;
            }
        }
        try self.spans.append(gpa, .{ .link = link, .line = line, .start = start, .end = end });
    }
};

/// Caller owns the result (allocated with `gpa`).
pub fn render(gpa: std.mem.Allocator, markdown: []const u8, opts: Options) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var r = Renderer{
        .gpa = gpa,
        .arena = arena_state.allocator(),
        .opts = opts,
    };
    errdefer r.out.deinit(gpa);

    var parser = std.mem.zeroes(c.MD_PARSER);
    parser.abi_version = 0;
    parser.flags = c.MD_DIALECT_GITHUB;
    if (opts.wikilinks) parser.flags |= c.MD_FLAG_WIKILINKS;
    parser.enter_block = enterBlock;
    parser.leave_block = leaveBlock;
    parser.enter_span = enterSpan;
    parser.leave_span = leaveSpan;
    parser.text = onText;

    const rc = c.md_parse(markdown.ptr, @intCast(markdown.len), &parser, &r);
    if (rc != 0) return r.fail_err orelse error.ParseFailed;

    return r.out.toOwnedSlice(gpa);
}

const WordRef = struct {
    style: Style,
    text: []const u8,
    space_before: bool,
    link: ?u32 = null, // index into Options.links.urls
    url_suffix: bool = false, // synthetic "(url)" word (skipped in slugs)
};
const Token = union(enum) { word: WordRef, hardbreak };

const ContainerKind = enum { doc, quote, ul, ol, li };
const Container = struct {
    kind: ContainerKind,
    tight: bool = true,
    ol_index: u32 = 1,
    ol_delim: u8 = '.',
    child_count: u32 = 0,
    prefix: []const u8 = "",
};

const Sep = enum { none, blank };

const Renderer = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    opts: Options,

    // First error raised inside a md4c callback (md_parse only reports a flag).
    fail_err: ?anyerror = null,

    out: std.ArrayList(u8) = .empty,
    stack: std.ArrayList(Container) = .empty,

    // Current leaf block inline accumulation.
    tokens: std.ArrayList(Token) = .empty,
    span_styles: std.ArrayList(Style) = .empty,
    cur_base: Style = .{},
    pending_space: bool = false,
    in_leaf: bool = false,

    // Block separation.
    pending_sep: Sep = .none,
    suppress_next_blank: bool = false,
    pending_first_prefix: ?[]const u8 = null,

    // Verbatim blocks (code / raw HTML).
    in_code_block: bool = false,
    in_html_block: bool = false,
    verbatim: std.ArrayList(u8) = .empty,
    code_lang: []const u8 = "",

    // Inline link/image: append the target after the visible text.
    link_stack: std.ArrayList(LinkRef) = .empty,

    // Anchor/link capture for the TUI (only active when opts.anchors/links).
    cur_link: ?u32 = null, // open MD_SPAN_A index into opts.links.urls
    in_heading: bool = false, // current leaf is a heading to anchor
    slugger: slug.Slugger = .{}, // arena-backed dedup map
    nl_pos: usize = 0, // out.items position already scanned for newlines
    nl_count: usize = 0, // newlines counted up to nl_pos

    // Table state.
    table: ?Table = null,
    cell_target: ?*std.ArrayList(u8) = null,
    cell_col: usize = 0, // display column reached while filling the current cell
    cell_links: std.ArrayList(CellLink) = .empty, // link runs in the current cell

    const LinkRef = struct { url: []const u8, show: bool };

    // A link's display-column run inside a table cell, relative to the cell's
    // content start. Resolved to an absolute LinkSpan when the row is drawn,
    // because a cell's final column only exists after borders/padding are laid.
    const CellLink = struct { idx: u32, start: usize, end: usize };
    const Cell = struct { text: []const u8, links: []const CellLink };

    const Table = struct {
        rows: std.ArrayList(std.ArrayList(Cell)),
        aligns: std.ArrayList(c.MD_ALIGN),
        in_head: bool = false,
        head_rows: u32 = 0,
    };

    fn topPrefix(self: *Renderer) []const u8 {
        const items = self.stack.items;
        return if (items.len > 0) items[items.len - 1].prefix else "";
    }

    fn top(self: *Renderer) *Container {
        return &self.stack.items[self.stack.items.len - 1];
    }

    fn curStyle(self: *Renderer) Style {
        var st = self.cur_base;
        for (self.span_styles.items) |s| st = Style.merge(st, s);
        return st;
    }

    /// Layers `base` over the theme's quote style when the leaf sits inside a
    /// blockquote: quoted body text picks up the quote attributes but keeps its own
    /// foreground, so headings stay coloured.
    fn leafBase(self: *Renderer, base: Style) Style {
        for (self.stack.items) |ct| {
            if (ct.kind == .quote) return Style.merge(self.opts.theme.quote, base);
        }
        return base;
    }

    /// Records the first callback error so render() can surface it, and returns the
    /// nonzero code that makes md_parse stop.
    fn abort(self: *Renderer, err: anyerror) c_int {
        if (self.fail_err == null) self.fail_err = err;
        return -1;
    }

    fn emitBlankIfNeeded(self: *Renderer) !void {
        if (self.suppress_next_blank) {
            self.suppress_next_blank = false;
            self.pending_sep = .none;
            return;
        }
        if (self.pending_sep == .blank) try self.out.append(self.gpa, '\n');
        self.pending_sep = .none;
    }

    fn concat(self: *Renderer, a: []const u8, b: []const u8) ![]const u8 {
        return std.mem.concat(self.arena, u8, &.{ a, b });
    }

    fn spaces(self: *Renderer, n: usize) ![]const u8 {
        const s = try self.arena.alloc(u8, n);
        @memset(s, ' ');
        return s;
    }

    fn styled(self: *Renderer, s: Style, text: []const u8) ![]const u8 {
        var list: std.ArrayList(u8) = .empty;
        try appendStyled(&list, self.arena, s, text);
        return list.items;
    }

    // --- inline accumulation ---

    fn addWord(self: *Renderer, wd: WordRef) !void {
        if (self.cell_target) |cell| {
            if (cell.items.len > 0 and wd.space_before) {
                try cell.append(self.arena, ' ');
                self.cell_col += 1;
            }
            try appendStyled(cell, self.arena, wd.style, wd.text);
            // Mirror the cell's display width so an open link's columns can be
            // located once the row is drawn (relative to the cell content start).
            const ww = width.displayWidth(wd.text);
            if (self.opts.links != null) {
                if (self.cur_link) |idx| try self.addCellLink(idx, self.cell_col, self.cell_col + ww);
            }
            self.cell_col += ww;
        } else {
            self.ensureLeaf();
            var w = wd;
            w.link = self.cur_link;
            try self.tokens.append(self.arena, .{ .word = w });
        }
    }

    /// Extends the last run when the same link continues in the current cell.
    fn addCellLink(self: *Renderer, idx: u32, start: usize, end: usize) !void {
        if (self.cell_links.items.len > 0) {
            const last = &self.cell_links.items[self.cell_links.items.len - 1];
            if (last.idx == idx) {
                last.end = end;
                return;
            }
        }
        try self.cell_links.append(self.arena, .{ .idx = idx, .start = start, .end = end });
    }

    fn splitWords(self: *Renderer, s: Style, text: []const u8) !void {
        var i: usize = 0;
        while (i < text.len) {
            const ch = text[i];
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
                self.pending_space = true;
                i += 1;
                continue;
            }
            const start = i;
            while (i < text.len) : (i += 1) {
                const cc = text[i];
                if (cc == ' ' or cc == '\t' or cc == '\n' or cc == '\r') break;
            }
            try self.addWord(.{ .style = s, .text = text[start..i], .space_before = self.pending_space });
            self.pending_space = false;
        }
    }

    fn handleText(self: *Renderer, ttype: c.MD_TEXTTYPE, text: []const u8) !void {
        if (self.in_code_block or self.in_html_block) {
            try self.verbatim.appendSlice(self.arena, text);
            return;
        }
        switch (ttype) {
            c.MD_TEXT_BR => {
                if (self.cell_target != null) {
                    self.pending_space = true;
                } else {
                    self.ensureLeaf();
                    try self.tokens.append(self.arena, .hardbreak);
                    self.pending_space = false;
                }
            },
            c.MD_TEXT_SOFTBR => self.pending_space = true,
            c.MD_TEXT_NULLCHAR => {
                try self.addWord(.{ .style = self.curStyle(), .text = "\u{FFFD}", .space_before = self.pending_space });
                self.pending_space = false;
            },
            c.MD_TEXT_ENTITY => {
                const dec = decodeEntity(self.arena, text) catch text;
                try self.addWord(.{ .style = self.curStyle(), .text = dec, .space_before = self.pending_space });
                self.pending_space = false;
            },
            else => try self.splitWords(self.curStyle(), text),
        }
    }

    // --- blocks ---

    fn enterBlock(self: *Renderer, t: c.MD_BLOCKTYPE, detail: ?*anyopaque) !void {
        // md4c omits MD_BLOCK_P callbacks inside tight lists, so inline content
        // can arrive without an enclosing leaf. Close any lazily-open leaf
        // before starting a new block.
        try self.flushLeafIfOpen();
        switch (t) {
            c.MD_BLOCK_DOC => try self.stack.append(self.arena, .{ .kind = .doc }),
            c.MD_BLOCK_QUOTE => {
                const bar = try self.styled(self.opts.theme.quote_bar, "\u{2502} ");
                const pfx = try self.concat(self.topPrefix(), bar);
                try self.stack.append(self.arena, .{ .kind = .quote, .prefix = pfx });
            },
            c.MD_BLOCK_UL => {
                const d: *c.MD_BLOCK_UL_DETAIL = @ptrCast(@alignCast(detail.?));
                if (self.top().kind == .li) self.suppress_next_blank = true; // nested list hugs its item
                try self.stack.append(self.arena, .{
                    .kind = .ul,
                    .tight = d.is_tight != 0,
                    .prefix = self.topPrefix(),
                });
            },
            c.MD_BLOCK_OL => {
                const d: *c.MD_BLOCK_OL_DETAIL = @ptrCast(@alignCast(detail.?));
                if (self.top().kind == .li) self.suppress_next_blank = true;
                try self.stack.append(self.arena, .{
                    .kind = .ol,
                    .tight = d.is_tight != 0,
                    .ol_index = d.start,
                    .ol_delim = @intCast(d.mark_delimiter),
                    .prefix = self.topPrefix(),
                });
            },
            c.MD_BLOCK_LI => {
                const d: *c.MD_BLOCK_LI_DETAIL = @ptrCast(@alignCast(detail.?));
                try self.enterListItem(d);
            },
            c.MD_BLOCK_HR => try self.emitRule(),
            c.MD_BLOCK_H => {
                const d: *c.MD_BLOCK_H_DETAIL = @ptrCast(@alignCast(detail.?));
                const lvl = std.math.clamp(d.level, 1, 6);
                self.beginLeaf(self.opts.theme.heading[lvl - 1]);
                self.in_heading = self.opts.anchors != null;
            },
            c.MD_BLOCK_P => self.beginLeaf(self.opts.theme.text),
            c.MD_BLOCK_CODE => {
                const d: *c.MD_BLOCK_CODE_DETAIL = @ptrCast(@alignCast(detail.?));
                // md4c frees the attribute buffer when this callback returns
                // (info strings with escapes or entities are heap-built), so
                // copy it: it is read later, in flushCodeBlock.
                self.code_lang = try self.arena.dupe(u8, attr(d.lang));
                self.in_code_block = true;
                self.verbatim.clearRetainingCapacity();
            },
            c.MD_BLOCK_HTML => {
                self.in_html_block = true;
                self.verbatim.clearRetainingCapacity();
            },
            c.MD_BLOCK_TABLE => self.table = .{ .rows = .empty, .aligns = .empty },
            c.MD_BLOCK_THEAD => if (self.table) |*tb| {
                tb.in_head = true;
            },
            c.MD_BLOCK_TBODY => if (self.table) |*tb| {
                tb.in_head = false;
            },
            c.MD_BLOCK_TR => if (self.table) |*tb| {
                try tb.rows.append(self.arena, .empty);
                if (tb.in_head) tb.head_rows += 1;
            },
            c.MD_BLOCK_TH, c.MD_BLOCK_TD => try self.enterCell(detail),
            else => {},
        }
    }

    fn leaveBlock(self: *Renderer, t: c.MD_BLOCKTYPE) !void {
        try self.flushLeafIfOpen();
        switch (t) {
            c.MD_BLOCK_DOC, c.MD_BLOCK_QUOTE, c.MD_BLOCK_UL, c.MD_BLOCK_OL, c.MD_BLOCK_LI => {
                if (t == c.MD_BLOCK_LI and self.pending_first_prefix != null) {
                    // Empty list item: still show its marker line.
                    try self.emitBlankIfNeeded();
                    try self.out.appendSlice(self.gpa, self.pending_first_prefix.?);
                    try self.out.append(self.gpa, '\n');
                    self.pending_first_prefix = null;
                    self.pending_sep = .blank;
                }
                _ = self.stack.pop();
            },
            // H and P are flushed by flushLeafIfOpen above.
            c.MD_BLOCK_CODE => {
                self.in_code_block = false;
                try self.flushCodeBlock();
                self.pending_sep = .blank;
            },
            c.MD_BLOCK_HTML => {
                self.in_html_block = false;
                try self.flushVerbatim(.{ .faint = true }, "");
                self.pending_sep = .blank;
            },
            c.MD_BLOCK_TABLE => {
                try self.emitTable();
                self.table = null;
                self.pending_sep = .blank;
            },
            c.MD_BLOCK_TH, c.MD_BLOCK_TD => try self.leaveCell(),
            else => {},
        }
    }

    fn enterListItem(self: *Renderer, d: *c.MD_BLOCK_LI_DETAIL) !void {
        const parent = self.top();
        parent.child_count += 1;
        if (parent.tight and parent.child_count > 1) self.suppress_next_blank = true;

        var marker_buf: [24]u8 = undefined;
        var marker: []const u8 = undefined;
        if (parent.kind == .ol) {
            marker = try std.fmt.bufPrint(&marker_buf, "{d}{c} ", .{ parent.ol_index, parent.ol_delim });
            parent.ol_index += 1;
        } else if (d.is_task != 0) {
            const checked = d.task_mark == 'x' or d.task_mark == 'X';
            marker = if (checked) "\u{2611} " else "\u{2610} ";
        } else {
            marker = "\u{2022} ";
        }
        const mwidth = width.displayWidth(marker);
        const styled_marker = try self.styled(self.opts.theme.list_marker, marker);

        const parent_prefix = parent.prefix;
        self.pending_first_prefix = try self.concat(parent_prefix, styled_marker);
        const cont = try self.concat(parent_prefix, try self.spaces(mwidth));
        try self.stack.append(self.arena, .{ .kind = .li, .prefix = cont });
    }

    fn beginLeaf(self: *Renderer, base: Style) void {
        self.tokens.clearRetainingCapacity();
        self.cur_base = self.leafBase(base);
        self.pending_space = false;
        self.in_leaf = true;
        self.in_heading = false;
    }

    /// Opens a default-styled leaf when inline content arrives outside an explicit
    /// paragraph/heading (tight list items, mostly).
    fn ensureLeaf(self: *Renderer) void {
        if (self.in_leaf or self.cell_target != null) return;
        self.beginLeaf(self.opts.theme.text);
    }

    fn flushLeafIfOpen(self: *Renderer) !void {
        if (!self.in_leaf) return;
        try self.flushLeaf();
        self.in_leaf = false;
        self.pending_sep = .blank;
    }

    fn flushLeaf(self: *Renderer) !void {
        const prefix_first = self.pending_first_prefix orelse self.topPrefix();
        const prefix_cont = self.topPrefix();
        self.pending_first_prefix = null;
        try self.emitBlankIfNeeded();
        if (self.in_heading) {
            self.in_heading = false;
            if (self.opts.anchors) |alist| try self.recordAnchor(alist);
        }
        try self.wrapTokens(prefix_first, prefix_cont);
    }

    /// Slugs the visible heading text, skipping the synthetic "(url)" words, and
    /// records the rendered line the heading starts on.
    fn recordAnchor(self: *Renderer, alist: *std.ArrayList(Anchor)) !void {
        var text: std.ArrayList(u8) = .empty;
        for (self.tokens.items) |tok| switch (tok) {
            .hardbreak => try text.append(self.arena, ' '),
            .word => |wd| {
                if (wd.url_suffix) continue;
                if (text.items.len > 0 and wd.space_before) try text.append(self.arena, ' ');
                try text.appendSlice(self.arena, wd.text);
            },
        };
        if (text.items.len == 0) return;
        const s = try self.slugger.slug(self.arena, text.items);
        try alist.append(self.gpa, .{ .line = self.currentLine(), .slug = try self.gpa.dupe(u8, s) });
    }

    fn wrapTokens(self: *Renderer, prefix_first: []const u8, prefix_cont: []const u8) !void {
        var line: std.ArrayList(WordRef) = .empty;
        defer line.deinit(self.arena);
        var line_w: usize = width.displayWidth(prefix_first);
        var is_first = true;
        var have = false;
        const limit = self.opts.width;

        for (self.tokens.items) |tok| {
            switch (tok) {
                .hardbreak => {
                    try self.emitLine(if (is_first) prefix_first else prefix_cont, line.items);
                    line.clearRetainingCapacity();
                    is_first = false;
                    have = false;
                    line_w = width.displayWidth(prefix_cont);
                },
                .word => |wd| {
                    const ww = width.displayWidth(wd.text);
                    const sep: usize = if (have and wd.space_before) 1 else 0;
                    if (have and line_w + sep + ww > limit) {
                        try self.emitLine(if (is_first) prefix_first else prefix_cont, line.items);
                        line.clearRetainingCapacity();
                        is_first = false;
                        line_w = width.displayWidth(prefix_cont);
                        var w2 = wd;
                        w2.space_before = false;
                        try line.append(self.arena, w2);
                        line_w += ww;
                        have = true;
                    } else {
                        try line.append(self.arena, wd);
                        line_w += sep + ww;
                        have = true;
                    }
                },
            }
        }
        if (have) try self.emitLine(if (is_first) prefix_first else prefix_cont, line.items);
    }

    fn emitLine(self: *Renderer, prefix: []const u8, words: []const WordRef) !void {
        // Mirror the emission with a display-column counter so link words can
        // be located exactly (the layout is prefix ++ [space?]word ...).
        const line_no: usize = if (self.opts.links != null) self.currentLine() else 0;
        var col: usize = if (self.opts.links != null) width.displayWidth(prefix) else 0;
        try self.out.appendSlice(self.gpa, prefix);
        var first = true;
        for (words) |wd| {
            if (!first and wd.space_before) {
                try self.out.append(self.gpa, ' ');
                col += 1;
            }
            first = false;
            try appendStyled(&self.out, self.gpa, wd.style, wd.text);
            if (self.opts.links) |lt| {
                const ww = width.displayWidth(wd.text);
                if (wd.link) |idx| try lt.addSpan(self.gpa, idx, line_no, col, col + ww);
                col += ww;
            }
        }
        try self.out.append(self.gpa, '\n');
    }

    /// The 0-based line index the next byte appended to `out` lands on. Counted
    /// incrementally, which holds because `out` only ever grows.
    fn currentLine(self: *Renderer) usize {
        self.nl_count += countNewlines(self.out.items[self.nl_pos..]);
        self.nl_pos = self.out.items.len;
        return self.nl_count;
    }

    /// ```mermaid blocks become diagram art (or source + note when unsupported).
    /// Other blocks get tree-sitter highlighting when the language is supported.
    fn flushCodeBlock(self: *Renderer) !void {
        const code = self.verbatim.items;
        if (std.mem.eql(u8, self.code_lang, "mermaid")) return self.flushMermaid(code);

        try self.emitBlankIfNeeded();
        const styles: ?[]?Style = if (registry.lookup(self.code_lang)) |lang|
            try highlighter.highlight(self.arena, code, lang, self.opts.theme.code_hl)
        else
            null;
        try self.emitCodeBody(code, styles);
    }

    /// Image in image modes (TUI overlay or inline escape, falling back to text
    /// art), text art otherwise, source + note when unsupported.
    fn flushMermaid(self: *Renderer, code: []const u8) !void {
        // Image modes rasterize the art with the embedded 8x8 font, which
        // only covers ASCII, so they render the diagram with .ascii = true.
        if (self.opts.placements != null or self.opts.image) {
            if (try mermaid.render(self.arena, code, .{ .ascii = true, .graph_dir = self.opts.graph_dir })) |art| {
                try self.emitBlankIfNeeded();
                if (self.opts.placements) |plist| {
                    // TUI: emit the text art (reserving rows) and record a
                    // placement so the pager can overlay a libvaxis image.
                    // Without pixels the art alone is still a valid rendering.
                    // Never write raw escape bytes into the pager text.
                    if (image.rasterizeRgba(self.arena, self.gpa, art) catch null) |rgba| {
                        const x: u16 = @intCast(width.displayWidth(self.topPrefix()) + 2);
                        const dims = artDims(art);
                        plist.append(self.gpa, .{
                            .line = countNewlines(self.out.items),
                            .rows = dims.rows,
                            .cols = dims.cols,
                            .x = x,
                            .w = rgba.w,
                            .h = rgba.h,
                            .rgba = rgba.px,
                        }) catch self.gpa.free(rgba.px); // drop the image, keep the art
                    }
                    return self.emitArt(art);
                }
                // CLI: Kitty uses the graphics protocol, everything else
                // truecolor half-blocks. On failure fall back to the art.
                const img: ?[]const u8 = switch (self.opts.protocol) {
                    .kitty => image.renderKitty(self.arena, art, self.opts.width) catch null,
                    .sixel => image.renderSixel(self.arena, art, self.opts.width) catch null,
                    else => image.render(self.arena, art, self.opts.width) catch null,
                };
                return self.emitArt(img orelse art);
            }
        } else if (try mermaid.render(self.arena, code, .{ .ascii = self.opts.ascii, .graph_dir = self.opts.graph_dir })) |art| {
            try self.emitBlankIfNeeded();
            return self.emitArt(art);
        }
        // Unsupported diagram type: note it, then show the source verbatim.
        try self.emitBlankIfNeeded();
        try self.emitMermaidNote(mermaid.typeName(code));
        try self.emitCodeBody(code, null);
    }

    fn emitCodeBody(self: *Renderer, code: []const u8, styles: ?[]?Style) !void {
        const prefix = self.topPrefix();
        var body = code;
        if (body.len > 0 and body[body.len - 1] == '\n') body = body[0 .. body.len - 1];

        var off: usize = 0;
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |ln| {
            const ls = off;
            off += ln.len + 1;
            try self.out.appendSlice(self.gpa, prefix);
            try self.out.appendSlice(self.gpa, "  ");
            if (styles) |st| {
                try self.emitHlLine(ln, st[ls .. ls + ln.len]);
            } else {
                try appendStyled(&self.out, self.gpa, self.opts.theme.code_block, ln);
            }
            try self.out.append(self.gpa, '\n');
        }
    }

    fn emitArt(self: *Renderer, art: []const u8) !void {
        const prefix = self.topPrefix();
        var it = std.mem.splitScalar(u8, art, '\n');
        while (it.next()) |ln| {
            try self.out.appendSlice(self.gpa, prefix);
            try self.out.appendSlice(self.gpa, "  ");
            try self.out.appendSlice(self.gpa, ln);
            try self.out.append(self.gpa, '\n');
        }
    }

    fn emitMermaidNote(self: *Renderer, kind: []const u8) !void {
        const prefix = self.topPrefix();
        const note = try std.fmt.allocPrint(self.arena, "\u{2500} mermaid ({s}): shown as source", .{kind});
        try self.out.appendSlice(self.gpa, prefix);
        try appendStyled(&self.out, self.gpa, .{ .faint = true }, note);
        try self.out.append(self.gpa, '\n');
    }

    /// Groups consecutive bytes sharing a style into runs. A null per-byte style
    /// falls back to the base code style.
    fn emitHlLine(self: *Renderer, ln: []const u8, line_styles: []const ?Style) !void {
        const base = self.opts.theme.code_block;
        var k: usize = 0;
        while (k < ln.len) {
            const s = line_styles[k] orelse base;
            var j = k + 1;
            while (j < ln.len and (line_styles[j] orelse base).eql(s)) : (j += 1) {}
            try appendStyled(&self.out, self.gpa, s, ln[k..j]);
            k = j;
        }
    }

    fn flushVerbatim(self: *Renderer, s: Style, indent: []const u8) !void {
        try self.emitBlankIfNeeded();
        const prefix = self.topPrefix();
        var body = self.verbatim.items;
        if (body.len > 0 and body[body.len - 1] == '\n') body = body[0 .. body.len - 1];
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |ln| {
            try self.out.appendSlice(self.gpa, prefix);
            try self.out.appendSlice(self.gpa, indent);
            try appendStyled(&self.out, self.gpa, s, ln);
            try self.out.append(self.gpa, '\n');
        }
    }

    fn emitRule(self: *Renderer) !void {
        try self.emitBlankIfNeeded();
        const prefix = self.topPrefix();
        const pw = width.displayWidth(prefix);
        const n = if (self.opts.width > pw) self.opts.width - pw else 0;
        try self.out.appendSlice(self.gpa, prefix);
        try theme.appendOpen(&self.out, self.gpa, self.opts.theme.rule);
        var i: usize = 0;
        while (i < n) : (i += 1) try self.out.appendSlice(self.gpa, "\u{2500}");
        if (!self.opts.theme.rule.isPlain()) try theme.appendReset(&self.out, self.gpa);
        try self.out.append(self.gpa, '\n');
        self.pending_sep = .blank;
    }

    // --- spans ---

    fn enterSpan(self: *Renderer, t: c.MD_SPANTYPE, detail: ?*anyopaque) !void {
        switch (t) {
            c.MD_SPAN_EM => try self.span_styles.append(self.arena, self.opts.theme.emph),
            c.MD_SPAN_STRONG => try self.span_styles.append(self.arena, self.opts.theme.strong),
            c.MD_SPAN_DEL => try self.span_styles.append(self.arena, self.opts.theme.del),
            c.MD_SPAN_U => try self.span_styles.append(self.arena, .{ .underline = true }),
            c.MD_SPAN_CODE => try self.span_styles.append(self.arena, self.opts.theme.code_span),
            c.MD_SPAN_A => {
                const d: *c.MD_SPAN_A_DETAIL = @ptrCast(@alignCast(detail.?));
                // md4c frees the attribute buffer when this callback returns
                // (URLs with escapes or entities are heap-built), so copy it.
                const href = try self.arena.dupe(u8, attr(d.href));
                try self.span_styles.append(self.arena, self.opts.theme.link_text);
                try self.link_stack.append(self.arena, .{ .url = href, .show = d.is_autolink == 0 });
                if (self.opts.links) |lt| {
                    self.cur_link = @intCast(lt.urls.items.len);
                    try lt.urls.append(self.gpa, try self.gpa.dupe(u8, href));
                }
            },
            c.MD_SPAN_IMG => {
                const d: *c.MD_SPAN_IMG_DETAIL = @ptrCast(@alignCast(detail.?));
                const src = try self.arena.dupe(u8, attr(d.src));
                try self.span_styles.append(self.arena, self.opts.theme.image);
                try self.link_stack.append(self.arena, .{ .url = src, .show = true });
            },
            c.MD_SPAN_WIKILINK => {
                const d: *c.MD_SPAN_WIKILINK_DETAIL = @ptrCast(@alignCast(detail.?));
                // md4c frees heap-built attributes when this callback returns.
                const target = try self.arena.dupe(u8, attr(d.target));
                const broken = if (self.opts.wikilink_check) |cb|
                    !cb.exists(cb.ctx, target)
                else
                    false;
                try self.span_styles.append(
                    self.arena,
                    if (broken) self.opts.theme.wikilink_broken else self.opts.theme.wikilink,
                );
            },
            else => try self.span_styles.append(self.arena, .{}),
        }
    }

    fn leaveSpan(self: *Renderer, t: c.MD_SPANTYPE) !void {
        _ = self.span_styles.pop();
        if (t == c.MD_SPAN_A or t == c.MD_SPAN_IMG) {
            const link = self.link_stack.pop().?;
            if (link.show and link.url.len > 0) {
                const txt = try std.mem.concat(self.arena, u8, &.{ "(", link.url, ")" });
                try self.addWord(.{ .style = self.opts.theme.link, .text = txt, .space_before = true, .url_suffix = true });
            }
            if (t == c.MD_SPAN_A) self.cur_link = null;
        }
    }

    // --- tables ---

    fn enterCell(self: *Renderer, detail: ?*anyopaque) !void {
        const tb = &self.table.?;
        if (tb.in_head) {
            const d: *c.MD_BLOCK_TD_DETAIL = @ptrCast(@alignCast(detail.?));
            try tb.aligns.append(self.arena, d.@"align");
        }
        const cell = try self.arena.create(std.ArrayList(u8));
        cell.* = .empty;
        self.cell_target = cell;
        self.cell_col = 0;
        self.cell_links.clearRetainingCapacity();
        self.cur_base = if (tb.in_head) self.opts.theme.table_header else self.opts.theme.text;
        self.pending_space = false;
    }

    fn leaveCell(self: *Renderer) !void {
        const tb = &self.table.?;
        const cell = self.cell_target.?;
        const row = &tb.rows.items[tb.rows.items.len - 1];
        // cell_links is reused across cells, so snapshot it into the arena.
        const links = try self.arena.dupe(CellLink, self.cell_links.items);
        try row.append(self.arena, .{ .text = cell.items, .links = links });
        self.cell_target = null;
    }

    fn emitTable(self: *Renderer) !void {
        const tb = &self.table.?;
        if (tb.rows.items.len == 0) return;
        try self.emitBlankIfNeeded();
        const prefix = self.topPrefix();
        const border = self.opts.theme.table_border;

        var ncols: usize = 0;
        for (tb.rows.items) |row| ncols = @max(ncols, row.items.len);
        if (ncols == 0) return;

        const col_w = try self.arena.alloc(usize, ncols);
        @memset(col_w, 0);
        for (tb.rows.items) |row| {
            for (row.items, 0..) |cell, i| col_w[i] = @max(col_w[i], width.displayWidth(cell.text));
        }

        try self.tableBorder(prefix, border, col_w, "\u{250C}", "\u{252C}", "\u{2510}");
        for (tb.rows.items, 0..) |row, ri| {
            try self.tableRow(prefix, border, col_w, row.items, tb.aligns.items);
            if (ri + 1 == tb.head_rows) {
                try self.tableBorder(prefix, border, col_w, "\u{251C}", "\u{253C}", "\u{2524}");
            }
        }
        try self.tableBorder(prefix, border, col_w, "\u{2514}", "\u{2534}", "\u{2518}");
    }

    fn tableBorder(self: *Renderer, prefix: []const u8, border: Style, col_w: []const usize, left: []const u8, mid: []const u8, right: []const u8) !void {
        try self.out.appendSlice(self.gpa, prefix);
        try theme.appendOpen(&self.out, self.gpa, border);
        try self.out.appendSlice(self.gpa, left);
        for (col_w, 0..) |w, i| {
            if (i > 0) try self.out.appendSlice(self.gpa, mid);
            var k: usize = 0;
            while (k < w + 2) : (k += 1) try self.out.appendSlice(self.gpa, "\u{2500}");
        }
        try self.out.appendSlice(self.gpa, right);
        if (!border.isPlain()) try theme.appendReset(&self.out, self.gpa);
        try self.out.append(self.gpa, '\n');
    }

    fn tableRow(self: *Renderer, prefix: []const u8, border: Style, col_w: []const usize, cells: []const Cell, aligns: []const c.MD_ALIGN) !void {
        // The row occupies exactly one rendered line (cells never wrap), so one
        // line index covers every link in it.
        const line_no: usize = if (self.opts.links != null) self.currentLine() else 0;
        try self.out.appendSlice(self.gpa, prefix);
        // Mirror the emission with a display-column counter, like emitLine, so a
        // cell link resolves to the column it is actually drawn at.
        var col: usize = if (self.opts.links != null) width.displayWidth(prefix) else 0;
        for (col_w, 0..) |w, i| {
            try appendStyled(&self.out, self.gpa, border, "\u{2502}");
            const cell: Cell = if (i < cells.len) cells[i] else .{ .text = "", .links = &[_]CellLink{} };
            const cw = width.displayWidth(cell.text);
            const pad = w - cw;
            const left_pad: usize = if (i < aligns.len) switch (aligns[i]) {
                c.MD_ALIGN_RIGHT => pad,
                c.MD_ALIGN_CENTER => pad / 2,
                else => 0,
            } else 0;
            try self.out.append(self.gpa, ' ');
            try self.out.appendNTimes(self.gpa, ' ', left_pad);
            col += 1 + 1 + left_pad; // border + leading space + left padding
            if (self.opts.links) |lt| {
                for (cell.links) |rec|
                    try lt.addSpan(self.gpa, rec.idx, line_no, col + rec.start, col + rec.end);
            }
            try self.out.appendSlice(self.gpa, cell.text);
            try self.out.appendNTimes(self.gpa, ' ', pad - left_pad);
            try self.out.append(self.gpa, ' ');
            col += cw + (pad - left_pad) + 1; // content + right padding + trailing space
        }
        try appendStyled(&self.out, self.gpa, border, "\u{2502}");
        try self.out.append(self.gpa, '\n');
    }
};

fn appendStyled(list: *std.ArrayList(u8), alloc: std.mem.Allocator, s: Style, txt: []const u8) !void {
    try theme.appendOpen(list, alloc, s);
    try list.appendSlice(alloc, txt);
    if (!s.isPlain()) try theme.appendReset(list, alloc);
}

fn attr(a: c.MD_ATTRIBUTE) []const u8 {
    if (a.text == null or a.size == 0) return "";
    return a.text[0..a.size];
}

/// A verbatim HTML entity ("&amp;", "&#39;", "&#x2014;") to its UTF-8 character.
/// Unknown names come back unchanged.
fn decodeEntity(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.eql(u8, s, "&amp;")) return "&";
    if (std.mem.eql(u8, s, "&lt;")) return "<";
    if (std.mem.eql(u8, s, "&gt;")) return ">";
    if (std.mem.eql(u8, s, "&quot;")) return "\"";
    if (std.mem.eql(u8, s, "&apos;") or std.mem.eql(u8, s, "&#39;")) return "'";
    if (std.mem.eql(u8, s, "&nbsp;")) return "\u{00A0}";
    if (s.len > 3 and s[0] == '&' and s[1] == '#') {
        const end = std.mem.indexOfScalar(u8, s, ';') orelse return s;
        const cp: u21 = blk: {
            if (s[2] == 'x' or s[2] == 'X') {
                break :blk std.fmt.parseInt(u21, s[3..end], 16) catch return s;
            }
            break :blk std.fmt.parseInt(u21, s[2..end], 10) catch return s;
        };
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return s;
        return alloc.dupe(u8, buf[0..n]);
    }
    return s;
}

fn countNewlines(s: []const u8) usize {
    var total: usize = 0;
    for (s) |ch| {
        if (ch == '\n') total += 1;
    }
    return total;
}

const Dims = struct { rows: u16, cols: u16 };

fn artDims(art: []const u8) Dims {
    var rows: usize = 0;
    var cols: usize = 0;
    var it = std.mem.splitScalar(u8, art, '\n');
    while (it.next()) |ln| {
        rows += 1;
        cols = @max(cols, width.displayWidth(ln));
    }
    return .{ .rows = @intCast(rows), .cols = @intCast(cols) };
}

// --- C callback trampolines ---

fn enterBlock(t: c.MD_BLOCKTYPE, detail: ?*anyopaque, ud: ?*anyopaque) callconv(.c) c_int {
    const self: *Renderer = @ptrCast(@alignCast(ud.?));
    self.enterBlock(t, detail) catch |err| return self.abort(err);
    return 0;
}

fn leaveBlock(t: c.MD_BLOCKTYPE, detail: ?*anyopaque, ud: ?*anyopaque) callconv(.c) c_int {
    _ = detail;
    const self: *Renderer = @ptrCast(@alignCast(ud.?));
    self.leaveBlock(t) catch |err| return self.abort(err);
    return 0;
}

fn enterSpan(t: c.MD_SPANTYPE, detail: ?*anyopaque, ud: ?*anyopaque) callconv(.c) c_int {
    const self: *Renderer = @ptrCast(@alignCast(ud.?));
    self.enterSpan(t, detail) catch |err| return self.abort(err);
    return 0;
}

fn leaveSpan(t: c.MD_SPANTYPE, detail: ?*anyopaque, ud: ?*anyopaque) callconv(.c) c_int {
    _ = detail;
    const self: *Renderer = @ptrCast(@alignCast(ud.?));
    self.leaveSpan(t) catch |err| return self.abort(err);
    return 0;
}

fn onText(t: c.MD_TEXTTYPE, text: [*c]const u8, size: c.MD_SIZE, ud: ?*anyopaque) callconv(.c) c_int {
    const self: *Renderer = @ptrCast(@alignCast(ud.?));
    self.handleText(t, text[0..size]) catch |err| return self.abort(err);
    return 0;
}

test "render: heading and paragraph with emphasis" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "# Title\n\nHello *world*.\n", .{ .width = 80, .theme = theme.notty });
    defer gpa.free(out);
    // notty theme => no ANSI, verify text and layout.
    try std.testing.expectEqualStrings("Title\n\nHello world.\n", out);
}

test "render: unordered list with wrapping prefix" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "- one\n- two\n", .{ .width = 80, .theme = theme.notty });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("\u{2022} one\n\u{2022} two\n", out);
}

test "render: blockquote prefixes lines" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "> quoted\n", .{ .width = 80, .theme = theme.notty });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("\u{2502} quoted\n", out);
}

test "render: ordered list numbers items" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "1. a\n2. b\n", .{ .width = 80, .theme = theme.notty });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("1. a\n2. b\n", out);
}

test "render: fenced code block is indented verbatim" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "```\nx = 1\n```\n", .{ .width = 80, .theme = theme.notty });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("  x = 1\n", out);
}

test "render: link shows url after the text" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "[t](http://e)\n", .{ .width = 80, .theme = theme.notty });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("t (http://e)\n", out);
}

test "render: link url with ampersand survives md4c attribute lifetime" {
    // URLs with '&' take md4c's heap-built attribute path, freed at callback
    // return. A stored slice would read freed memory in leaveSpan.
    const gpa = std.testing.allocator;
    const out = try render(gpa, "[x](http://e/?a=1&b=2)\n", .{ .width = 80, .theme = theme.notty });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("x (http://e/?a=1&b=2)\n", out);
}

test "render: nested list hugs its parent item" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "- a\n  - b\n", .{ .width = 80, .theme = theme.notty });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("\u{2022} a\n  \u{2022} b\n", out);
}

test "render: table honors column alignment markers" {
    const gpa = std.testing.allocator;
    const src = "| aaa | bbb | ccc |\n|:----|:---:|----:|\n| x | y | z |\n";
    const out = try render(gpa, src, .{ .width = 80, .theme = theme.notty });
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\u{2502} x   \u{2502}  y  \u{2502}   z \u{2502}") != null);
}

test "render: word wrap respects width" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "aaa bbb ccc\n", .{ .width = 7, .theme = theme.notty });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("aaa bbb\nccc\n", out);
}

test "render: fence info with entity survives md4c attribute lifetime" {
    // Info strings with entities take md4c's heap-built attribute path, freed
    // at callback return. A stored slice would read freed memory later, in
    // flushCodeBlock.
    const gpa = std.testing.allocator;
    const out = try render(gpa, "```c&amp;\nx = 1\n```\n", .{ .width = 80, .theme = theme.notty });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("  x = 1\n", out);
}

test "render: blockquote body picks up the quote style" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "> quoted\n", .{ .width = 80, .theme = theme.dark });
    defer gpa.free(out);
    // dark quote = italic+faint => SGR opens with faint (2) then italic (3).
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[2;3mquoted") != null);
}

test "render: image mode emits a kitty graphics sequence" {
    const gpa = std.testing.allocator;
    const src = "```mermaid\npie\n\"A\": 1\n```\n";
    const out = try render(gpa, src, .{ .width = 80, .theme = theme.notty, .image = true, .protocol = .kitty });
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b_G") != null);
}

test "render: TUI placements record an image and keep escapes out of the text" {
    const gpa = std.testing.allocator;
    var places: std.ArrayList(Placement) = .empty;
    defer {
        for (places.items) |p| gpa.free(p.rgba);
        places.deinit(gpa);
    }
    const src = "```mermaid\npie\n\"A\": 1\n```\n";
    const out = try render(gpa, src, .{ .width = 80, .theme = theme.notty, .image = true, .protocol = .kitty, .placements = &places });
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 1), places.items.len);
    // The pager parses only plain SGR text: no raw kitty/sixel bytes allowed.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b_G") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1bP") == null);
}

test "render: unsupported diagram in image mode shows the source" {
    const gpa = std.testing.allocator;
    const src = "```mermaid\nunknowndiagram\nx\n```\n";
    const out = try render(gpa, src, .{ .width = 80, .theme = theme.notty, .image = true, .protocol = .kitty });
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "shown as source") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b_G") == null);
}

test "render: wikilinks are literal text unless enabled" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "a [[Page]] b\n", .{ .width = 80, .theme = theme.notty });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("a [[Page]] b\n", out);
}

test "render: wikilink shows the label styled, without brackets or target" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "[[Page|label]]\n", .{ .width = 80, .theme = theme.dark, .wikilinks = true });
    defer gpa.free(out);
    // dark wikilink = underline (4) + fg 79.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[4;38;5;79mlabel") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[[") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Page") == null);
}

test "render: wikilink_check styles unresolvable targets as broken" {
    const S = struct {
        fn exists(_: ?*anyopaque, target: []const u8) bool {
            return std.mem.eql(u8, target, "known");
        }
    };
    const gpa = std.testing.allocator;
    const out = try render(gpa, "[[known]] and [[missing]]\n", .{
        .width = 80,
        .theme = theme.dark,
        .wikilinks = true,
        .wikilink_check = .{ .exists = S.exists },
    });
    defer gpa.free(out);
    // dark wikilink = underline (4) + fg 79, wikilink_broken = strike (9) + fg 203.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[4;38;5;79mknown") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[9;38;5;203mmissing") != null);
}

fn freeAnchors(gpa: std.mem.Allocator, anchors: *std.ArrayList(Anchor)) void {
    for (anchors.items) |a| gpa.free(a.slug);
    anchors.deinit(gpa);
}

test "render: anchors record heading lines and deduplicated slugs" {
    const gpa = std.testing.allocator;
    var anchors: std.ArrayList(Anchor) = .empty;
    defer freeAnchors(gpa, &anchors);
    const out = try render(gpa, "# Quick start\n\ntext\n\n## Quick start\n", .{ .width = 80, .theme = theme.notty, .anchors = &anchors });
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 2), anchors.items.len);
    try std.testing.expectEqual(@as(usize, 0), anchors.items[0].line);
    try std.testing.expectEqualStrings("quick-start", anchors.items[0].slug);
    try std.testing.expectEqual(@as(usize, 4), anchors.items[1].line);
    try std.testing.expectEqualStrings("quick-start-1", anchors.items[1].slug);
}

test "render: heading slug skips the synthetic url suffix" {
    const gpa = std.testing.allocator;
    var anchors: std.ArrayList(Anchor) = .empty;
    defer freeAnchors(gpa, &anchors);
    const out = try render(gpa, "# See [docs](http://d)\n", .{ .width = 80, .theme = theme.notty, .anchors = &anchors });
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 1), anchors.items.len);
    try std.testing.expectEqualStrings("see-docs", anchors.items[0].slug);
}

test "render: link table records the url and one merged span" {
    const gpa = std.testing.allocator;
    var links: LinkTable = .{};
    defer links.deinit(gpa);
    const out = try render(gpa, "[click me](http://x)\n", .{ .width = 80, .theme = theme.notty, .links = &links });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("click me (http://x)\n", out);
    try std.testing.expectEqual(@as(usize, 1), links.urls.items.len);
    try std.testing.expectEqualStrings("http://x", links.urls.items[0]);
    // "click", "me" and "(http://x)" merge into one span over the whole line.
    try std.testing.expectEqual(@as(usize, 1), links.spans.items.len);
    try std.testing.expectEqual(LinkSpan{ .link = 0, .line = 0, .start = 0, .end = 19 }, links.spans.items[0]);
}

test "render: wrapped link records one span per rendered line" {
    const gpa = std.testing.allocator;
    var links: LinkTable = .{};
    defer links.deinit(gpa);
    const out = try render(gpa, "[click me](http://x)\n", .{ .width = 10, .theme = theme.notty, .links = &links });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("click me\n(http://x)\n", out);
    try std.testing.expectEqual(@as(usize, 2), links.spans.items.len);
    try std.testing.expectEqual(LinkSpan{ .link = 0, .line = 0, .start = 0, .end = 8 }, links.spans.items[0]);
    try std.testing.expectEqual(LinkSpan{ .link = 0, .line = 1, .start = 0, .end = 10 }, links.spans.items[1]);
}

test "render: link span accounts for the list prefix" {
    const gpa = std.testing.allocator;
    var links: LinkTable = .{};
    defer links.deinit(gpa);
    const out = try render(gpa, "- [a](http://x)\n", .{ .width = 80, .theme = theme.notty, .links = &links });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("\u{2022} a (http://x)\n", out);
    try std.testing.expectEqual(@as(usize, 1), links.spans.items.len);
    try std.testing.expectEqual(LinkSpan{ .link = 0, .line = 0, .start = 2, .end = 14 }, links.spans.items[0]);
}

test "render: link inside a table cell is reachable at its drawn position" {
    const gpa = std.testing.allocator;
    var links: LinkTable = .{};
    defer links.deinit(gpa);
    // A link in a table cell must be Tab-navigable where it is displayed, not
    // silently dropped (which it was while table cells had no link geometry).
    const src = "| A | B |\n| - | - |\n| [x](x.md) | y |\n";
    const out = try render(gpa, src, .{ .width = 80, .theme = theme.notty, .links = &links });
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 1), links.urls.items.len);
    try std.testing.expectEqualStrings("x.md", links.urls.items[0]);
    try std.testing.expectEqual(@as(usize, 1), links.spans.items.len);
    // Lines: top border, header, mid border, body. The link text "x (x.md)" is
    // 8 wide and starts at column 2 (cell border + one leading space).
    try std.testing.expectEqual(LinkSpan{ .link = 0, .line = 3, .start = 2, .end = 10 }, links.spans.items[0]);
}

test "render: output bytes are identical with and without collection" {
    const gpa = std.testing.allocator;
    // The table row also carries a cell link: collecting its geometry must not
    // change a single rendered byte.
    const src = "# T\n\n- [a](http://x) word\n\n[Quick start](#quick-start)\n\n| H |\n| - |\n| [t](t.md) |\n";
    const plain = try render(gpa, src, .{ .width = 80, .theme = theme.notty });
    defer gpa.free(plain);
    var links: LinkTable = .{};
    defer links.deinit(gpa);
    var anchors: std.ArrayList(Anchor) = .empty;
    defer freeAnchors(gpa, &anchors);
    const collected = try render(gpa, src, .{ .width = 80, .theme = theme.notty, .links = &links, .anchors = &anchors });
    defer gpa.free(collected);
    try std.testing.expectEqualStrings(plain, collected);
}
