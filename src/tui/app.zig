//! Interactive full-screen pager built on libvaxis (no file browser): renders a
//! single Markdown file, scrolls it, and re-renders on terminal resize. In image
//! mode it overlays Mermaid diagrams as libvaxis images over the reserved text
//! rows.

const std = @import("std");
const Io = std.Io;
const vaxis = @import("vaxis");

const render = @import("md");
const options = render.options;
const ansiseg = render.ansiseg;
const Pager = @import("pager.zig").Pager;
const Search = @import("search.zig").Search;
const wikilink = @import("../wikilink.zig");

/// A diagram image placed over text rows in the pager.
const TuiImg = struct {
    line: usize,
    rows: u16,
    cols: u16,
    x: u16,
    img: vaxis.Image,
};

/// Interactive link/anchor state for the loaded document (rebuilt on resize,
/// since rendered lines and columns depend on the wrap width).
const Links = struct {
    table: render.LinkTable = .{},
    anchors: std.ArrayList(render.Anchor) = .empty,
    groups: std.ArrayList(Group) = .empty, // one entry per link with >= 1 span
    selected: ?usize = null, // index into groups

    /// A link's contiguous run of spans in table.spans.
    const Group = struct { link: u32, first: usize, count: usize };

    fn deinit(self: *Links, gpa: std.mem.Allocator) void {
        self.table.deinit(gpa);
        for (self.anchors.items) |a| gpa.free(a.slug);
        self.anchors.deinit(gpa);
        self.groups.deinit(gpa);
    }

    fn reset(self: *Links, gpa: std.mem.Allocator) void {
        self.deinit(gpa);
        self.* = .{};
    }

    /// One link's spans are contiguous by construction, in document order.
    fn buildGroups(self: *Links, gpa: std.mem.Allocator) !void {
        self.groups.clearRetainingCapacity();
        for (self.table.spans.items, 0..) |sp, i| {
            if (self.groups.items.len > 0) {
                const last = &self.groups.items[self.groups.items.len - 1];
                if (last.link == sp.link) {
                    last.count += 1;
                    continue;
                }
            }
            try self.groups.append(gpa, .{ .link = sp.link, .first = i, .count = 1 });
        }
    }

    fn urlOf(self: *const Links, gi: usize) []const u8 {
        return self.table.urls.items[self.groups.items[gi].link];
    }

    fn spansOf(self: *const Links, gi: usize) []const render.LinkSpan {
        const g = self.groups.items[gi];
        return self.table.spans.items[g.first .. g.first + g.count];
    }

    fn hitTest(self: *const Links, line: usize, col: usize) ?usize {
        for (self.groups.items, 0..) |g, gi| {
            for (self.table.spans.items[g.first .. g.first + g.count]) |sp| {
                if (sp.line == line and col >= sp.start and col < sp.end) return gi;
            }
        }
        return null;
    }

    /// `target` must arrive lowercased and percent-decoded.
    fn anchorLine(self: *const Links, target: []const u8) ?usize {
        for (self.anchors.items) |a| {
            if (std.mem.eql(u8, a.slug, target)) return a.line;
        }
        return null;
    }

    fn selectNext(self: *Links) void {
        const n = self.groups.items.len;
        if (n == 0) return;
        self.selected = if (self.selected) |s| (s + 1) % n else 0;
    }

    fn selectPrev(self: *Links) void {
        const n = self.groups.items.len;
        if (n == 0) return;
        self.selected = if (self.selected) |s| (s + n - 1) % n else n - 1;
    }
};

/// A document the user can go back to with Backspace.
const Hist = struct { path: []u8, offset: usize };

const NavReq = struct {
    path: []u8, // gpa-owned filesystem path to open
    frag: ?[]u8, // gpa-owned #fragment to jump to after loading
    ret_offset: ?usize, // back navigation: restore this offset instead
    push: bool, // push the current document onto the history
};

/// A mouse text selection, kept in document coordinates so it survives scrolling
/// and resizes. `moved` distinguishes a drag (a selection to copy) from a plain
/// click (which follows a link instead).
const Sel = struct {
    a_line: usize, // anchor: where the button went down
    a_col: usize,
    h_line: usize, // head: the current drag position
    h_col: usize,
    moved: bool = false,

    const Point = struct { line: usize, col: usize };

    /// (start, end) ordered so start precedes end in the document.
    fn normalized(self: Sel) struct { start: Point, end: Point } {
        const a: Point = .{ .line = self.a_line, .col = self.a_col };
        const h: Point = .{ .line = self.h_line, .col = self.h_col };
        const a_first = self.a_line < self.h_line or
            (self.a_line == self.h_line and self.a_col <= self.h_col);
        return if (a_first) .{ .start = a, .end = h } else .{ .start = h, .end = a };
    }
};

/// The pager's mutable state, shared by the event handlers: the current
/// document (owned), its rendered form, and the interactive search/link/history
/// state.
const Session = struct {
    io: Io,
    gpa: std.mem.Allocator,
    vx: *vaxis.Vaxis,
    writer: *std.Io.Writer,
    opts: options.Options,
    ws: vaxis.Winsize,
    imgs: std.ArrayList(TuiImg) = .empty,
    links: Links = .{},
    // Current document (owned): file navigation replaces these, Backspace
    // walks the history back.
    doc: []u8 = &.{},
    doc_path: []u8 = &.{},
    history: std.ArrayList(Hist) = .empty,
    content: []u8 = &.{},
    pager: Pager = .{ .lines = &.{} },
    search: Search = .{},
    /// Static footer message set by followLink, cleared on the next event.
    status: ?[]const u8 = null,
    /// Mouse text selection (in document coordinates), null when there is none.
    sel: ?Sel = null,
    /// True between a left button-down and its release.
    dragging: bool = false,

    fn deinit(self: *Session) void {
        const gpa = self.gpa;
        self.search.deinit(gpa);
        self.pager.deinit(gpa);
        gpa.free(self.content);
        for (self.history.items) |h| gpa.free(h.path);
        self.history.deinit(gpa);
        gpa.free(self.doc_path);
        gpa.free(self.doc);
        self.links.deinit(gpa);
        freeImages(self.vx, self.writer, &self.imgs);
        self.imgs.deinit(gpa);
    }

    fn bodyH(self: *const Session) usize {
        return bodyHeight(self.ws.rows);
    }

    /// One-shot startup navigation (--goto-line / --find). Track the resolved
    /// target separately from pager.offset: scrollTo clamps near the end of the
    /// document, and --find must scope from the true section start.
    fn startupNav(self: *Session) !void {
        const body_h = self.bodyH();
        var start_line: usize = 0;
        if (self.opts.goto_line) |src_line| {
            const k = render.headingOrdinalAt(self.doc, src_line);
            if (k > 0 and self.links.anchors.items.len > 0) {
                // defensive clamp: a heading whose text renders empty records
                // no anchor, which can leave k one past the list
                const idx = @min(k, self.links.anchors.items.len) - 1;
                start_line = self.links.anchors.items[idx].line;
                self.pager.scrollTo(start_line, body_h);
            } // k == 0: the line precedes every heading, stay at the top
        }
        if (self.opts.find) |needle| if (needle.len > 0) {
            // Seed the interactive state, so --find opens highlighted and n/N
            // walks the occurrences right away.
            try self.search.query.appendSlice(self.gpa, needle);
            try self.search.rebuild(self.gpa, self.pager.lines);
            self.search.selectFrom(start_line);
            if (self.search.currentLine()) |ln| {
                self.pager.scrollTo(ln, body_h);
            } else self.status = "pattern not found";
        };
    }

    /// True means quit.
    fn handleKey(self: *Session, key: vaxis.Key) !bool {
        const body_h = self.bodyH();
        self.sel = null; // any key dismisses the mouse selection highlight
        if (self.search.input) return self.handleSearchKey(key, body_h);
        if (key.matches('c', .{ .ctrl = true }) or
            key.matches('q', .{}) or
            key.matches(vaxis.Key.escape, .{}))
        {
            return true;
        } else if (key.matches('/', .{})) {
            self.search.input = true;
            self.search.saved_offset = self.pager.offset;
            self.search.clear(self.gpa);
        } else if (key.matches('n', .{})) {
            self.search.next();
            if (self.search.currentLine()) |ln| showMatch(&self.pager, ln, body_h);
        } else if (key.matches('N', .{})) {
            self.search.prev();
            if (self.search.currentLine()) |ln| showMatch(&self.pager, ln, body_h);
        } else if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
            self.pager.scrollBy(-1, body_h);
        } else if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
            self.pager.scrollBy(1, body_h);
        } else if (key.matches(vaxis.Key.page_up, .{})) {
            self.pager.scrollBy(-@as(isize, @intCast(body_h)), body_h);
        } else if (key.matches(vaxis.Key.page_down, .{}) or key.matches(vaxis.Key.space, .{})) {
            self.pager.scrollBy(@intCast(body_h), body_h);
        } else if (key.matches('g', .{})) {
            self.pager.toStart();
        } else if (key.matches('G', .{})) {
            self.pager.toEnd(body_h);
        } else if (key.matches(vaxis.Key.tab, .{ .shift = true })) {
            self.links.selectPrev();
            if (self.links.selected) |gi| ensureVisible(&self.pager, self.links.spansOf(gi)[0], body_h);
        } else if (key.matches(vaxis.Key.tab, .{})) {
            self.links.selectNext();
            if (self.links.selected) |gi| ensureVisible(&self.pager, self.links.spansOf(gi)[0], body_h);
        } else if (key.matches(vaxis.Key.enter, .{})) {
            if (self.links.selected) |gi| {
                if (try self.followLink(gi, body_h)) |req| try self.navigate(req);
            }
        } else if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.history.pop()) |h| {
                try self.navigate(.{ .path = h.path, .frag = null, .ret_offset = h.offset, .push = false });
            }
        }
        return false;
    }

    /// The prompt owns the keyboard: plain characters type into the query, so
    /// the quit keys must not be tested first. True means quit.
    fn handleSearchKey(self: *Session, key: vaxis.Key, body_h: usize) !bool {
        const gpa = self.gpa;
        if (key.matches('c', .{ .ctrl = true })) return true;
        if (key.matches(vaxis.Key.escape, .{})) {
            self.search.input = false;
            self.search.clear(gpa);
            self.pager.scrollTo(self.search.saved_offset, body_h);
        } else if (key.matches(vaxis.Key.enter, .{})) {
            self.search.input = false;
            if (self.search.matches.len == 0) self.status = "pattern not found";
        } else {
            var edited = false;
            if (key.matches(vaxis.Key.backspace, .{})) {
                self.search.popCodepoint();
                edited = true;
            } else if (key.text) |t| {
                try self.search.query.appendSlice(gpa, t);
                edited = true;
            }
            if (edited) {
                // Incremental: re-scan and re-anchor on every keystroke, always
                // from where the prompt opened, so the target only moves when
                // the query stops matching earlier.
                try self.search.rebuild(gpa, self.pager.lines);
                self.search.selectFrom(self.search.saved_offset);
                if (self.search.currentLine()) |ln| showMatch(&self.pager, ln, body_h);
            }
        }
        return false;
    }

    fn handleMouse(self: *Session, mouse: vaxis.Mouse) !void {
        const body_h = self.bodyH();
        if (mouse.button == .wheel_up) {
            self.sel = null;
            self.pager.scrollBy(-3, body_h);
        } else if (mouse.button == .wheel_down) {
            self.sel = null;
            self.pager.scrollBy(3, body_h);
        } else if (mouse.type == .press and mouse.button == .left) {
            const line = self.pager.offset + clampRow(mouse.row, body_h);
            const col = clampCol(mouse.col);
            self.dragging = true;
            self.sel = .{ .a_line = line, .a_col = col, .h_line = line, .h_col = col };
        } else if (mouse.type == .drag and self.dragging) {
            if (self.sel) |*sel| {
                const line = self.pager.offset + clampRow(mouse.row, body_h);
                const col = clampCol(mouse.col);
                if (line != sel.a_line or col != sel.a_col) sel.moved = true;
                sel.h_line = line;
                sel.h_col = col;
            }
        } else if (mouse.type == .release and self.dragging) {
            self.dragging = false;
            const sel = self.sel orelse return;
            if (!sel.moved) {
                // A plain click (no drag): follow a link under the release point.
                self.sel = null;
                if (self.links.hitTest(sel.a_line, sel.a_col)) |gi| {
                    self.links.selected = gi;
                    if (try self.followLink(gi, body_h)) |req| try self.navigate(req);
                }
            } else {
                // A drag: copy the selected text. Keep sel set so it stays lit.
                const text = try self.selectedText(sel);
                defer self.gpa.free(text);
                if (text.len == 0) return;
                // here, try copy to system clipboard
                self.vx.copyToSystemClipboard(self.writer, text, self.gpa) catch {
                    self.status = "copy failed";
                    return;
                };
                self.status = "copied";
            }
        }
    }

    fn selectedText(self: *Session, sel: Sel) ![]u8 {
        const win = self.vx.window();
        const body_h = self.bodyH();
        const n = sel.normalized();
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);

        var line = n.start.line;
        while (line <= n.end.line) : (line += 1) {
            if (line < self.pager.offset) continue;
            const row = line - self.pager.offset;
            if (row >= body_h) break;
            const col_start: usize = if (line == n.start.line) n.start.col else 0;
            // End column is inclusive on the last line. Earlier lines run to the
            // window edge and shed their trailing blanks below.
            const col_end: usize = if (line == n.end.line) n.end.col + 1 else win.width;

            const line_start = out.items.len;
            var col = col_start;
            while (col < col_end and col < win.width) {
                const cell = win.readCell(@intCast(col), @intCast(row)) orelse {
                    col += 1;
                    continue;
                };
                try out.appendSlice(self.gpa, cell.char.grapheme);
                col += if (cell.char.width > 1) cell.char.width else 1;
            }
            while (out.items.len > line_start and out.items[out.items.len - 1] == ' ')
                _ = out.pop();
            if (line != n.end.line) try out.append(self.gpa, '\n');
        }
        return out.toOwnedSlice(self.gpa);
    }

    fn handleResize(self: *Session, new_ws: vaxis.Winsize) !void {
        const gpa = self.gpa;
        self.sel = null; // rewrapped lines invalidate the selection's coordinates
        try self.vx.resize(gpa, self.writer, new_ws);
        self.ws = new_ws;
        freeImages(self.vx, self.writer, &self.imgs);
        // Group ordinals are width-independent (spans move, links don't), so
        // the selection survives the rebuild.
        const sel = self.links.selected;
        self.links.reset(gpa); // line/column tables depend on the wrap width
        // Build the new content/pager before releasing the old ones so a
        // failure here doesn't leave the deferred cleanup pointing at
        // already-freed memory.
        const new_content = try loadContent(self.io, gpa, self.vx, self.writer, self.doc_path, self.doc, self.opts, self.ws.cols, &self.imgs, &self.links);
        errdefer gpa.free(new_content);
        const new_pager = try Pager.init(gpa, new_content);
        gpa.free(self.content);
        self.pager.deinit(gpa);
        self.content = new_content;
        self.pager = new_pager;
        self.pager.clamp(self.bodyH());
        if (sel) |s| {
            if (s < self.links.groups.items.len) self.links.selected = s;
        }
        // Match lines and columns are wrap-width dependent too.
        try self.search.rebuild(gpa, self.pager.lines);
    }

    /// Internal anchors scroll the pager, web links go to xdg-open, Markdown
    /// targets come back as a navigation request, anything else lands in the
    /// footer.
    fn followLink(self: *Session, gi: usize, body_h: usize) !?NavReq {
        const url = self.links.urlOf(gi);
        if (url.len > 0 and url[0] == '#') {
            if (!jumpToAnchor(&self.links, &self.pager, url[1..], body_h)) self.status = "anchor not found";
        } else if (std.mem.startsWith(u8, url, "http://") or
            std.mem.startsWith(u8, url, "https://") or
            std.mem.startsWith(u8, url, "mailto:"))
        {
            openExternal(self.io, url) catch {
                self.status = "could not open link";
            };
        } else if (std.mem.indexOf(u8, url, "://") == null and isMarkdownPath(splitTarget(url).path)) {
            return try resolveFileTarget(self.gpa, self.doc_path, splitTarget(url));
        } else {
            self.status = "link target not supported";
        }
        return null;
    }

    /// Loads `req.path` and swaps it in as the current document. A file that
    /// cannot be read only sets the footer message.
    fn navigate(self: *Session, req: NavReq) !void {
        const gpa = self.gpa;
        const new_doc = Io.Dir.cwd().readFileAlloc(self.io, req.path, gpa, .unlimited) catch {
            gpa.free(req.path);
            if (req.frag) |f| gpa.free(f);
            self.status = "cannot open file";
            return;
        };
        errdefer gpa.free(new_doc);
        defer if (req.frag) |f| gpa.free(f);
        try self.history.ensureUnusedCapacity(gpa, 1);
        freeImages(self.vx, self.writer, &self.imgs);
        self.links.reset(gpa);
        // req.path, not doc_path: doc_path still names the outgoing document
        // until the commit point below.
        const new_content = try loadContent(self.io, gpa, self.vx, self.writer, req.path, new_doc, self.opts, self.ws.cols, &self.imgs, &self.links);
        errdefer gpa.free(new_content);
        const new_pager = try Pager.init(gpa, new_content);
        // Commit point: nothing below can fail. Hand the outgoing document to
        // the history (Backspace) or release it (back navigation).
        if (req.push) {
            self.history.appendAssumeCapacity(.{ .path = self.doc_path, .offset = self.pager.offset });
        } else {
            gpa.free(self.doc_path);
        }
        self.doc_path = req.path;
        gpa.free(self.doc);
        self.doc = new_doc;
        gpa.free(self.content);
        self.pager.deinit(gpa);
        self.content = new_content;
        self.pager = new_pager;
        // Another document: the matches and their counter described the old
        // one.
        self.search.clear(gpa);
        const body_h = self.bodyH();
        if (req.ret_offset) |off| {
            self.pager.offset = off;
            self.pager.clamp(body_h);
        } else if (req.frag) |f| {
            if (!jumpToAnchor(&self.links, &self.pager, f, body_h)) self.status = "anchor not found";
        }
    }

    fn draw(self: *Session, arena: std.mem.Allocator) !void {
        const win = self.vx.window();
        win.clear();
        const body_h = self.bodyH();

        var y: u16 = 0;
        while (y < body_h) : (y += 1) {
            const idx = self.pager.offset + y;
            if (idx >= self.pager.lines.len) break;
            const segs = try ansiseg.lineToSegments(arena, self.pager.lines[idx]);
            if (segs.len > 0) _ = win.print(segs, .{ .row_offset = y, .wrap = .none });
        }

        // Highlight the selected link by reversing its visible cells.
        if (self.links.selected) |gi| {
            for (self.links.spansOf(gi)) |sp| {
                if (sp.line < self.pager.offset) continue;
                const row = sp.line - self.pager.offset;
                if (row >= body_h) continue;
                var col = sp.start;
                while (col < sp.end) : (col += 1) {
                    const c = std.math.cast(u16, col) orelse break;
                    var cell = win.readCell(c, @intCast(row)) orelse break; // off-screen
                    cell.style.reverse = true;
                    win.writeCell(c, @intCast(row), cell);
                }
            }
        }

        // The renderer never emits reverse (see ansiseg.applyParams), so reversing
        // marks a match whatever its styling. The current match gets explicit colours:
        // the text underneath may already be bold or underlined.
        for (self.search.matches, 0..) |m, i| {
            if (m.line < self.pager.offset) continue;
            const row = m.line - self.pager.offset;
            if (row >= body_h) continue;
            var col = m.start;
            while (col < m.end) : (col += 1) {
                const c = std.math.cast(u16, col) orelse break;
                var cell = win.readCell(c, @intCast(row)) orelse break; // off-screen
                if (self.search.current == i) {
                    cell.style.reverse = false;
                    cell.style.bg = .{ .index = 11 }; // bright yellow, legible on both themes
                    cell.style.fg = .{ .index = 0 };
                } else {
                    cell.style.reverse = true;
                }
                win.writeCell(c, @intCast(row), cell);
            }
        }

        // Reverse the mouse selection's cells, clipped to the visible body and to
        // each line's text (never the trailing blanks).
        if (self.sel) |sel| if (sel.moved) {
            const n = sel.normalized();
            var line = n.start.line;
            while (line <= n.end.line) : (line += 1) {
                if (line < self.pager.offset) continue;
                const row = line - self.pager.offset;
                if (row >= body_h) break;
                const content_end = lineContentEnd(win, @intCast(row));
                const col_start: usize = if (line == n.start.line) n.start.col else 0;
                const want_end: usize = if (line == n.end.line) n.end.col + 1 else content_end;
                const col_end = @min(want_end, content_end);
                var col = col_start;
                while (col < col_end) : (col += 1) {
                    const c = std.math.cast(u16, col) orelse break;
                    var cell = win.readCell(c, @intCast(row)) orelse break;
                    cell.style.reverse = true;
                    win.writeCell(c, @intCast(row), cell);
                }
            }
        };

        // Overlay diagram images over their (text-art) rows when fully visible.
        for (self.imgs.items) |t| {
            if (t.line < self.pager.offset) continue;
            const row = t.line - self.pager.offset;
            if (row + t.rows > body_h) continue;
            const child = win.child(.{
                .x_off = @intCast(t.x),
                .y_off = @intCast(row),
                .width = t.cols,
                .height = t.rows,
            });
            t.img.draw(child, .{ .scale = .fit }) catch {};
        }

        // While the prompt is open the footer *is* the prompt: the query with a
        // cursor, plus live feedback when nothing matches.
        const counter = if (self.search.matches.len > 0)
            try std.fmt.allocPrint(arena, "  \u{00b7}  {d}/{d}", .{ (self.search.current orelse 0) + 1, self.search.matches.len })
        else
            "";
        // The row never wraps, so whatever runs past the terminal width is lost:
        // everything below is sized to fit 80 columns.
        const footer = if (self.search.input)
            try std.fmt.allocPrint(arena, "/{s}\u{258c}{s}", .{
                self.search.query.items,
                if (self.search.query.items.len > 0 and self.search.matches.len == 0) "  \u{00b7}  no match" else "",
            })
        else if (self.status) |msg|
            // A message displaces the hints: appended, it would be the part cut off.
            try std.fmt.allocPrint(arena, "{d}%{s}  \u{00b7}  {s}", .{ self.pager.percent(body_h), counter, msg })
        else blk: {
            // PgUp/PgDn is the hint that goes: a pager user reaches for it untold.
            // "/ search" is there to be discovered, and n/N shows up once matches
            // exist. "Tab link / Enter open" appears only when the document has
            // navigable links, so the bar never advertises a no-op.
            const nav = if (self.links.groups.items.len > 0) " \u{00b7} Tab link \u{00b7} Enter open" else "";
            break :blk try std.fmt.allocPrint(
                arena,
                "{d}%{s}  \u{00b7}  \u{2191}/\u{2193} \u{00b7} g/G \u{00b7} {s}{s}{s} \u{00b7} q quit",
                .{
                    self.pager.percent(body_h),
                    counter,
                    if (self.search.matches.len > 0) "n/N" else "/ search",
                    nav,
                    if (self.history.items.len > 0) " \u{00b7} Bksp back" else "",
                },
            );
        };
        _ = win.print(
            &.{.{ .text = footer, .style = .{ .dim = true } }},
            .{ .row_offset = @intCast(body_h), .wrap = .none },
        );
    }
};

/// Drives the TUI until the user quits. `path`, `markdown` and `opts` are
/// borrowed. `path` locates `markdown`, so relative link targets can resolve.
pub fn run(
    io: Io,
    gpa: std.mem.Allocator,
    env: *std.process.Environ.Map,
    path: []const u8,
    markdown: []const u8,
    opts: options.Options,
) !void {
    var tty_buf: [16 * 1024]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();
    const writer = tty.writer();

    var vx = try vaxis.init(io, gpa, env, .{});
    defer vx.deinit(gpa, writer);

    var loop: vaxis.Loop(vaxis.Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();
    try loop.installResizeHandler();

    try vx.enterAltScreen(writer);
    vx.queryTerminal(writer, std.Io.Duration.fromMilliseconds(50)) catch {};
    vx.setMouseMode(writer, true) catch {}; // vx.deinit restores the terminal

    const ws = try tty.getWinsize();
    try vx.resize(gpa, writer, ws);

    var s: Session = .{ .io = io, .gpa = gpa, .vx = &vx, .writer = writer, .opts = opts, .ws = ws };
    defer s.deinit();
    s.doc = try gpa.dupe(u8, markdown);
    s.doc_path = try gpa.dupe(u8, path);
    s.content = try loadContent(io, gpa, &vx, writer, s.doc_path, s.doc, opts, ws.cols, &s.imgs, &s.links);
    s.pager = try Pager.init(gpa, s.content);

    var frame = std.heap.ArenaAllocator.init(gpa);
    defer frame.deinit();

    try s.startupNav();
    try s.draw(frame.allocator());
    try vx.render(writer);

    while (true) {
        const ev = try loop.nextEvent();
        s.status = null;
        switch (ev) {
            .key_press => |key| if (try s.handleKey(key)) return,
            .mouse => |mouse| try s.handleMouse(mouse),
            .winsize => |new_ws| try s.handleResize(new_ws),
            else => {},
        }
        _ = frame.reset(.retain_capacity);
        try s.draw(frame.allocator());
        try vx.render(writer);
    }
}

/// Mouse rows outside the text body clamp to it: a drag past the footer or
/// above the top still yields a valid viewport row.
fn clampRow(row: i16, body_h: usize) usize {
    if (row < 0 or body_h == 0) return 0;
    return @min(@as(usize, @intCast(row)), body_h - 1);
}

fn clampCol(col: i16) usize {
    return if (col < 0) 0 else @intCast(col);
}

/// Exclusive column just past the last non-blank cell on row (0 if blank):
/// selection highlighting stops at the text instead of painting trailing space.
fn lineContentEnd(win: vaxis.Window, row: u16) usize {
    var end: usize = 0;
    var col: u16 = 0;
    while (col < win.width) : (col += 1) {
        const cell = win.readCell(col, row) orelse continue;
        const blank = cell.char.grapheme.len == 1 and cell.char.grapheme[0] == ' ';
        if (!blank) end = col + 1;
    }
    return end;
}

/// An off-screen match goes to the top line (like --find and less). One already
/// on screen leaves the viewport alone, so typing a query does not jitter it.
fn showMatch(pager: *Pager, line: usize, body_h: usize) void {
    if (line >= pager.offset and line < pager.offset + body_h) return;
    pager.scrollTo(line, body_h);
}

fn ensureVisible(pager: *Pager, sp: render.LinkSpan, body_h: usize) void {
    if (sp.line < pager.offset) {
        pager.offset = sp.line;
    } else if (body_h > 0 and sp.line >= pager.offset + body_h) {
        pager.offset = sp.line + 1 - body_h;
    }
}

/// `frag` must be percent-decoded and ASCII-lowercased. False when not found.
fn jumpToAnchor(links: *const Links, pager: *Pager, frag: []const u8, body_h: usize) bool {
    var buf: [256]u8 = undefined;
    if (frag.len > buf.len) return false;
    @memcpy(buf[0..frag.len], frag);
    const dec = std.Uri.percentDecodeInPlace(buf[0..frag.len]);
    const target = std.ascii.lowerString(dec, dec);
    if (links.anchorLine(target)) |line| {
        pager.scrollTo(line, body_h);
        return true;
    }
    return false;
}

const SplitTarget = struct { path: []const u8, frag: ?[]const u8 };

fn splitTarget(url: []const u8) SplitTarget {
    if (std.mem.indexOfScalar(u8, url, '#')) |i| {
        return .{ .path = url[0..i], .frag = url[i + 1 ..] };
    }
    return .{ .path = url, .frag = null };
}

fn isMarkdownPath(p: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(p, ".md") or std.ascii.endsWithIgnoreCase(p, ".markdown");
}

/// Resolves against the current file's directory. Absolute targets are kept as-is.
fn resolveFileTarget(gpa: std.mem.Allocator, doc_path: []const u8, target: SplitTarget) !NavReq {
    const raw = try gpa.dupe(u8, target.path);
    defer gpa.free(raw);
    const decoded = std.Uri.percentDecodeInPlace(raw);
    const new_path = if (std.fs.path.isAbsolute(decoded))
        try gpa.dupe(u8, decoded)
    else if (std.fs.path.dirname(doc_path)) |dir|
        try std.fs.path.join(gpa, &.{ dir, decoded })
    else
        try gpa.dupe(u8, decoded);
    errdefer gpa.free(new_path);
    const frag: ?[]u8 = if (target.frag) |f| try gpa.dupe(u8, f) else null;
    return .{ .path = new_path, .frag = frag, .ret_offset = null, .push = true };
}

/// Hands `url` to xdg-open, detached from the TUI: a transient sh backgrounds it
/// (no zombie, no blocking) and all stdio goes to /dev/null, so the child can
/// never write into the alternate screen.
fn openExternal(io: Io, url: []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", "\"$0\" \"$1\" &", "xdg-open", url },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = child.wait(io) catch {};
}

fn bodyHeight(rows: u16) usize {
    return if (rows > 1) rows - 1 else 0; // reserve one row for the footer
}

/// Renders the document for the current width, filling `links` (heading anchors +
/// link cells). In image mode it also transmits each diagram image and records its
/// placement.
///
/// `doc_path` names the document `markdown` came from: wikilink targets resolve
/// against its directory, so navigation must pass the incoming path, not the
/// outgoing one.
fn loadContent(
    io: Io,
    gpa: std.mem.Allocator,
    vx: *vaxis.Vaxis,
    writer: *std.Io.Writer,
    doc_path: []const u8,
    markdown: []const u8,
    opts: options.Options,
    cols: u16,
    imgs: *std.ArrayList(TuiImg),
    links: *Links,
) ![]u8 {
    var o = opts;
    o.width = @min(cols, options.max_width);
    if (o.width == 0) o.width = options.default_width;

    // Declared in this frame, not inside the `if`: o.wikilink_check borrows it
    // and it has to stay alive through the render call below.
    var wl: wikilink.Resolver = .{ .io = io, .dir = std.fs.path.dirname(doc_path) orelse "." };
    if (o.wikilinks) o.wikilink_check = wl.check();

    var places: std.ArrayList(render.Placement) = .empty;
    defer places.deinit(gpa);
    // On a render failure the placements collected so far still own pixels.
    errdefer for (places.items) |p| gpa.free(p.rgba);
    const content = try render.renderToAnsiCollect(gpa, markdown, o, .{
        .placements = if (o.image) &places else null,
        .anchors = &links.anchors,
        .links = &links.table,
    });
    errdefer gpa.free(content);
    try links.buildGroups(gpa);
    for (places.items) |p| {
        defer gpa.free(p.rgba);
        // transmitImage copies into its own arena, p.rgba stays ours to free.
        var zimg = vaxis.zigimg.Image.fromRawPixelsOwned(p.w, p.h, p.rgba, .rgba32) catch continue;
        const img = vx.transmitImage(gpa, writer, &zimg, .rgba) catch continue;
        imgs.append(gpa, .{ .line = p.line, .rows = p.rows, .cols = p.cols, .x = p.x, .img = img }) catch {
            vx.freeImage(writer, img.id); // untracked images would never be freed
        };
    }
    return content;
}

fn freeImages(vx: *vaxis.Vaxis, writer: *std.Io.Writer, imgs: *std.ArrayList(TuiImg)) void {
    for (imgs.items) |t| vx.freeImage(writer, t.img.id);
    imgs.clearRetainingCapacity();
}

test "splitTarget separates the path from the fragment" {
    const t1 = splitTarget("docs/other.md#quick-start");
    try std.testing.expectEqualStrings("docs/other.md", t1.path);
    try std.testing.expectEqualStrings("quick-start", t1.frag.?);
    const t2 = splitTarget("other.md");
    try std.testing.expectEqualStrings("other.md", t2.path);
    try std.testing.expect(t2.frag == null);
}

test "Sel.normalized orders endpoints by line then column" {
    const up = Sel{ .a_line = 5, .a_col = 2, .h_line = 3, .h_col = 9 };
    const un = up.normalized();
    try std.testing.expectEqual(@as(usize, 3), un.start.line);
    try std.testing.expectEqual(@as(usize, 9), un.start.col);
    try std.testing.expectEqual(@as(usize, 5), un.end.line);

    // Same line, head left of anchor: order by column.
    const left = Sel{ .a_line = 4, .a_col = 8, .h_line = 4, .h_col = 1 };
    const ln = left.normalized();
    try std.testing.expectEqual(@as(usize, 1), ln.start.col);
    try std.testing.expectEqual(@as(usize, 8), ln.end.col);

    // Forward drag stays as-is.
    const fwd = Sel{ .a_line = 2, .a_col = 0, .h_line = 2, .h_col = 6 };
    const fn_ = fwd.normalized();
    try std.testing.expectEqual(@as(usize, 0), fn_.start.col);
    try std.testing.expectEqual(@as(usize, 6), fn_.end.col);
}

test "isMarkdownPath accepts .md/.markdown case-insensitively" {
    try std.testing.expect(isMarkdownPath("a.md"));
    try std.testing.expect(isMarkdownPath("A.MD"));
    try std.testing.expect(isMarkdownPath("b.markdown"));
    try std.testing.expect(!isMarkdownPath("c.txt"));
    try std.testing.expect(!isMarkdownPath("md"));
}

test "resolveFileTarget resolves against the current file's directory" {
    const gpa = std.testing.allocator;
    const req = try resolveFileTarget(gpa, "docs/guide/index.md", splitTarget("../api/ref.md#intro"));
    defer {
        gpa.free(req.path);
        if (req.frag) |f| gpa.free(f);
    }
    try std.testing.expectEqualStrings("docs/guide/../api/ref.md", req.path);
    try std.testing.expectEqualStrings("intro", req.frag.?);
    try std.testing.expect(req.push);

    // Percent-encoded names decode, a doc without a directory stays local.
    const req2 = try resolveFileTarget(gpa, "index.md", splitTarget("My%20Notes.md"));
    defer gpa.free(req2.path);
    try std.testing.expectEqualStrings("My Notes.md", req2.path);
    try std.testing.expect(req2.frag == null);
}
