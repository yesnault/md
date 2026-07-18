//! Syntax Ref: https://mermaid.ai/open-source/syntax/sequenceDiagram.html
//!
//! 2D layout for Mermaid sequence diagrams: participants as boxes across the
//! top, vertical lifelines, and horizontal message arrows (left/right) with the
//! message text above each arrow. Self-messages draw as a small loop hanging
//! off the right of the lifeline. Supports combined fragments (loop/alt/opt/...)
//! drawn as nested labelled frames, activation bars on lifelines, and notes.
//! Crossings with lifelines resolve via the canvas line layer.

const std = @import("std");
const Canvas = @import("canvas.zig").Canvas;
const BoxGlyphs = @import("canvas.zig").BoxGlyphs;
const putCentered = @import("canvas.zig").putCentered;
const width = @import("../markdown/width.zig");
const canvas = @import("canvas.zig");
const txt = @import("text.zig"); // aliased 'txt': a 'text' param in drawNote would shadow it
const ws = txt.ws;

pub const Participant = struct { display: []const u8 };

pub const Kind = enum { msg, note, frag_open, frag_else, frag_close, activate, deactivate };

/// One event, source order. Fields an event doesn't use stay at their defaults.
pub const Event = struct {
    kind: Kind,
    from: usize = 0,
    to: usize = 0,
    text: []const u8 = "",
    label: []const u8 = "", // fragment / else label (incl. keyword)
    a: usize = 0, // note span (left participant)
    b: usize = 0, // note span (right participant)
    who: usize = 0, // activate / deactivate participant
};

const box_h: usize = 3;
const gap: usize = 4; // between participant boxes

const Frame = struct { open: usize, close: usize, depth: usize, label: []const u8 };
const Else = struct { row: usize, label: []const u8 };
const Msg = struct { from: usize, to: usize, text: []const u8, row: usize };
const Note = struct { a: usize, b: usize, text: []const u8, top: usize };
const Bar = struct { who: usize, y0: usize, y1: usize };

/// The event list once rows are resolved: every drawable with its canvas row(s).
const Script = struct {
    frames: []Frame,
    elses: []Else,
    msgs: []Msg,
    notes: []Note,
    bars: []Bar,
    rows: usize, // last row used by an event
    max_depth: usize, // deepest fragment nesting
};

fn collectRows(arena: std.mem.Allocator, events: []const Event, n: usize) !Script {
    var frames: std.ArrayList(Frame) = .empty;
    var fstack: std.ArrayList(usize) = .empty;
    var elses: std.ArrayList(Else) = .empty;
    var msgs: std.ArrayList(Msg) = .empty;
    var notes: std.ArrayList(Note) = .empty;
    var bars: std.ArrayList(Bar) = .empty;
    const act = try arena.alloc(std.ArrayList(usize), n);
    for (act) |*a| a.* = .empty;

    var row = box_h + 1;
    var depth: usize = 0;
    var max_depth: usize = 0;
    for (events) |e| {
        switch (e.kind) {
            .frag_open => {
                try frames.append(arena, .{ .open = row, .close = row, .depth = depth, .label = e.label });
                try fstack.append(arena, frames.items.len - 1);
                depth += 1;
                max_depth = @max(max_depth, depth);
                row += 1;
            },
            .frag_else => {
                try elses.append(arena, .{ .row = row, .label = e.label });
                row += 1;
            },
            .frag_close => {
                if (fstack.items.len > 0) {
                    const fi = fstack.pop().?;
                    frames.items[fi].close = row;
                    depth -= 1;
                }
                row += 1;
            },
            .msg => {
                try msgs.append(arena, .{ .from = e.from, .to = e.to, .text = e.text, .row = row + 1 });
                // A self-message needs a third row: text, loop top, loop bottom.
                row += if (e.from == e.to) 3 else 2;
            },
            .note => {
                try notes.append(arena, .{ .a = e.a, .b = e.b, .text = e.text, .top = row });
                row += 3;
            },
            .activate => try act[e.who].append(arena, row),
            .deactivate => if (act[e.who].items.len > 0) {
                const s = act[e.who].pop().?;
                try bars.append(arena, .{ .who = e.who, .y0 = s, .y1 = row });
            },
        }
    }
    return .{
        .frames = frames.items,
        .elses = elses.items,
        .msgs = msgs.items,
        .notes = notes.items,
        .bars = bars.items,
        .rows = row,
        .max_depth = max_depth,
    };
}

pub fn layout(arena: std.mem.Allocator, parts: []const Participant, events: []const Event, ascii: bool) ![]const u8 {
    const n = parts.len;
    if (n == 0) return error.Empty;

    const a_right: u21 = if (ascii) '>' else '\u{25B6}'; // ▶
    const a_left: u21 = if (ascii) '<' else '\u{25C0}'; // ◀
    const act_glyph: u21 = if (ascii) '#' else '\u{2503}'; // ┃
    const box = if (ascii) BoxGlyphs.ascii else BoxGlyphs.unicode;

    // Participant widths and base x positions (before margin).
    const bw = try arena.alloc(usize, n);
    const bxbase = try arena.alloc(usize, n);
    var cursor_x: usize = 0;
    for (parts, 0..) |p, i| {
        bw[i] = @max(width.displayWidth(p.display) + 4, 5);
        bxbase[i] = cursor_x;
        cursor_x += bw[i] + gap;
    }
    const base_w = if (cursor_x > gap) cursor_x - gap else cursor_x;

    const script = try collectRows(arena, events, n);

    // Width: enough for participants (+ frame margins) and the widest frame label.
    var canvas_w = base_w + 2 * (script.max_depth + 1);
    for (script.frames) |f| {
        const need = 2 * f.depth + 3 + width.displayWidth(f.label);
        if (need > canvas_w) canvas_w = need;
    }
    const left_margin = (canvas_w - base_w) / 2;
    const canvas_h = script.rows + 1;

    const bx = try arena.alloc(usize, n);
    for (0..n) |i| bx[i] = bxbase[i] + left_margin;

    // Self-loops hang off the right of their lifeline. Widen the canvas (on
    // the right only, left_margin is already fixed) so loop and text fit.
    for (script.msgs) |m| if (m.from == m.to and m.from < n) {
        canvas_w = @max(canvas_w, center(bx[m.from], bw[m.from]) + 4 + width.displayWidth(m.text));
    };

    var c = try Canvas.init(arena, canvas_w, canvas_h);

    // Lifelines.
    for (0..n) |i| c.lineV(box_h, canvas_h - 1, center(bx[i], bw[i]));

    // Activation bars on lifelines (below frames/messages so labels and arrows
    // stay readable on top).
    for (script.bars) |b| {
        const cx = center(bx[b.who], bw[b.who]);
        var y = b.y0;
        while (y <= b.y1 and y < canvas_h) : (y += 1) c.set(cx, y, act_glyph);
    }

    // Fragment frames (outermost first so nested borders sit on top).
    for (script.frames) |f| {
        drawFrame(c, box, f.depth, f.open, canvas_w - 1 - f.depth, f.close, f.label);
    }
    for (script.elses) |el| {
        // Divider across the innermost-ish width (full minus 1 each side).
        c.hline(1, canvas_w - 2, el.row, box.h);
        if (el.label.len > 0) putLabel(c, 2, el.row, el.label, box.h);
    }

    // Messages.
    for (script.msgs) |m| {
        if (m.from >= n or m.to >= n) continue;
        if (m.from == m.to) {
            // Self-message: a small loop off the right of the lifeline,
            // re-entering it one row below, with the text above.
            const cx = center(bx[m.from], bw[m.from]);
            c.lineH(cx, cx + 3, m.row);
            c.lineV(m.row, m.row + 1, cx + 3);
            c.lineH(cx + 1, cx + 3, m.row + 1);
            c.set(cx + 1, m.row + 1, a_left);
            if (m.text.len > 0) c.putStr(cx + 2, m.row - 1, m.text);
            continue;
        }
        const c1 = center(bx[m.from], bw[m.from]);
        const c2 = center(bx[m.to], bw[m.to]);
        c.lineH(c1, c2, m.row);
        c.set(c2, m.row, if (c2 > c1) a_right else a_left);
        if (m.text.len > 0) putCentered(c, @min(c1, c2), @max(c1, c2) - @min(c1, c2), m.row - 1, m.text);
    }

    // Notes (boxes spanning the involved participants).
    for (script.notes) |nt| {
        const lo = @min(nt.a, nt.b);
        const hi = @max(nt.a, nt.b);
        const lw = width.displayWidth(nt.text);
        const x0 = if (bx[lo] > 1) bx[lo] - 1 else 0;
        var x1 = bx[hi] + bw[hi];
        if (x1 < x0 + lw + 3) x1 = x0 + lw + 3;
        // TODO: canvas_w is sized from participants and messages, never from note
        // text, so this clamp undoes the widening above and a long note overflows
        // its own right border.
        if (x1 >= canvas_w) x1 = canvas_w - 1;
        drawNote(c, box, x0, nt.top, x1, nt.text);
    }

    // Participant boxes (drawn last so they sit above lifelines).
    for (0..n) |i| drawBox(c, box, bx[i], 0, bw[i], parts[i].display);

    return c.toString(ascii);
}

fn center(x: usize, w: usize) usize {
    return x + w / 2;
}

fn drawBox(c: Canvas, g: BoxGlyphs, x: usize, y: usize, w: usize, label: []const u8) void {
    canvas.drawBox(c, g, x, y, w, 3);
    putCentered(c, x + 1, w - 2, y + 1, label);
}

fn drawFrame(c: Canvas, g: BoxGlyphs, x0: usize, y0: usize, x1: usize, y1: usize, label: []const u8) void {
    if (x1 <= x0 + 1 or y1 <= y0) return;
    canvas.drawBox(c, g, x0, y0, x1 - x0 + 1, y1 - y0 + 1);
    if (label.len > 0 and x0 + 2 < x1) putLabel(c, x0 + 2, y0, label, g.h);
}

/// Writes `s` over a border row, drawing `fill` for spaces so the border, not a
/// lifeline, shows between the words.
fn putLabel(c: Canvas, x: usize, y: usize, s: []const u8, fill: u21) void {
    var cx = x;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + len, s.len);
        const cp = std.unicode.utf8Decode(s[i..end]) catch s[i];
        c.set(cx, y, if (cp == ' ') fill else cp);
        cx += 1;
        i = end;
    }
}

fn drawNote(c: Canvas, g: BoxGlyphs, x0: usize, y0: usize, x1: usize, text: []const u8) void {
    if (x1 <= x0 + 1) return;
    canvas.drawBox(c, g, x0, y0, x1 - x0 + 1, 3);
    putCentered(c, x0 + 1, x1 - x0 - 1, y0 + 1, text);
}

// --- parser: Mermaid sequenceDiagram syntax → the layout engine above ---

pub fn render(arena: std.mem.Allocator, src: []const u8, ascii: bool) ![]const u8 {
    var ps = txt.Interner(Participant).init(arena);
    var events: std.ArrayList(Event) = .empty;

    var it = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, ws);
        if (first) {
            first = false;
            continue; // skip "sequenceDiagram"
        }
        if (t.len == 0 or std.mem.startsWith(u8, t, "%%")) continue;
        if (std.mem.startsWith(u8, t, "participant ") or std.mem.startsWith(u8, t, "actor ")) {
            const after = if (std.mem.startsWith(u8, t, "participant ")) t[12..] else t[6..];
            const decl = std.mem.trim(u8, after, ws);
            if (std.mem.indexOf(u8, decl, " as ")) |i| {
                const id = std.mem.trim(u8, decl[0..i], ws);
                const name = std.mem.trim(u8, decl[i + 4 ..], ws);
                const idx = try ps.ensure(id, .{ .display = id });
                ps.items.items[idx].display = name;
            } else {
                _ = try ps.ensure(decl, .{ .display = decl });
            }
            continue;
        }
        // Combined-fragment open (loop/alt/opt/par/critical/break) → frame.
        if (fragOpenKeyword(t)) |label| {
            try events.append(arena, .{ .kind = .frag_open, .label = label });
            continue;
        }
        if (std.mem.eql(u8, t, "else") or std.mem.startsWith(u8, t, "else ")) {
            try events.append(arena, .{ .kind = .frag_else, .label = std.mem.trim(u8, t[4..], ws) });
            continue;
        }
        if (std.mem.eql(u8, t, "end")) {
            try events.append(arena, .{ .kind = .frag_close });
            continue;
        }
        if (std.mem.startsWith(u8, t, "activate ")) {
            const id = std.mem.trim(u8, t[9..], ws);
            const w = try ps.ensure(id, .{ .display = id });
            try events.append(arena, .{ .kind = .activate, .who = w });
            continue;
        }
        if (std.mem.startsWith(u8, t, "deactivate ")) {
            const id = std.mem.trim(u8, t[11..], ws);
            const w = try ps.ensure(id, .{ .display = id });
            try events.append(arena, .{ .kind = .deactivate, .who = w });
            continue;
        }
        if (std.mem.startsWith(u8, t, "note ") or std.mem.startsWith(u8, t, "Note ")) {
            if (parseNote(t)) |nt| {
                const a = try ps.ensure(nt.a, .{ .display = nt.a });
                const b = try ps.ensure(nt.b, .{ .display = nt.b });
                try events.append(arena, .{ .kind = .note, .a = a, .b = b, .text = nt.text });
            }
            continue;
        }
        if (parseMessage(t)) |m| {
            const fi = try ps.ensure(m.from, .{ .display = m.from });
            const ti = try ps.ensure(m.to, .{ .display = m.to });
            try events.append(arena, .{ .kind = .msg, .from = fi, .to = ti, .text = m.text });
            if (m.act_target) try events.append(arena, .{ .kind = .activate, .who = ti });
            if (m.deact_source) try events.append(arena, .{ .kind = .deactivate, .who = fi });
        }
    }
    var has_msg = false;
    for (events.items) |e| if (e.kind == .msg) {
        has_msg = true;
        break;
    };
    if (!has_msg) return error.NoMessages;
    return layout(arena, ps.items.items, events.items, ascii);
}

const frag_kws = [_][]const u8{ "loop", "alt", "opt", "par", "critical", "break" };

/// The whole line as a frame label when it opens a combined fragment, else null.
fn fragOpenKeyword(t: []const u8) ?[]const u8 {
    for (frag_kws) |k| {
        if (std.mem.eql(u8, t, k)) return t;
        if (std.mem.startsWith(u8, t, k) and t.len > k.len and (t[k.len] == ' ' or t[k.len] == '\t')) return t;
    }
    return null;
}

const NoteSpec = struct { a: []const u8, b: []const u8, text: []const u8 };

fn parseNote(t: []const u8) ?NoteSpec {
    const rest = std.mem.trim(u8, t[5..], ws); // after "note "
    const ci = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    const head = std.mem.trim(u8, rest[0..ci], ws);
    const label = std.mem.trim(u8, rest[ci + 1 ..], ws);
    if (std.mem.startsWith(u8, head, "over ")) {
        const spec = std.mem.trim(u8, head[5..], ws);
        if (std.mem.indexOfScalar(u8, spec, ',')) |cm| {
            return .{ .a = std.mem.trim(u8, spec[0..cm], ws), .b = std.mem.trim(u8, spec[cm + 1 ..], ws), .text = label };
        }
        return .{ .a = spec, .b = spec, .text = label };
    }
    if (std.mem.startsWith(u8, head, "left of ")) {
        const p = std.mem.trim(u8, head[8..], ws);
        return .{ .a = p, .b = p, .text = label };
    }
    if (std.mem.startsWith(u8, head, "right of ")) {
        const p = std.mem.trim(u8, head[9..], ws);
        return .{ .a = p, .b = p, .text = label };
    }
    return null;
}

const Message = struct { from: []const u8, to: []const u8, text: []const u8, act_target: bool = false, deact_source: bool = false };
const seq_ops = [_][]const u8{ "-->>", "->>", "-->", "->", "--x", "-x", "--)", "-)" };

fn parseMessage(line: []const u8) ?Message {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const head = line[0..colon];
    const label = std.mem.trim(u8, line[colon + 1 ..], ws);
    for (seq_ops) |op| {
        if (std.mem.indexOf(u8, head, op)) |i| {
            const from = std.mem.trim(u8, head[0..i], ws);
            var to = std.mem.trim(u8, head[i + op.len ..], ws);
            if (from.len == 0 or to.len == 0) return null;
            // Activation suffix: `->>+B` activates B. `-->>-A` deactivates the source.
            var act = false;
            var deact = false;
            if (to[0] == '+') {
                act = true;
                to = std.mem.trim(u8, to[1..], ws);
            } else if (to[0] == '-') {
                deact = true;
                to = std.mem.trim(u8, to[1..], ws);
            }
            if (to.len == 0) return null;
            return .{ .from = from, .to = to, .text = label, .act_target = act, .deact_source = deact };
        }
    }
    return null;
}

test "sequence draws participant boxes and message arrows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parts = [_]Participant{ .{ .display = "Alice" }, .{ .display = "Bob" } };
    const events = [_]Event{
        .{ .kind = .msg, .from = 0, .to = 1, .text = "Hello" },
        .{ .kind = .msg, .from = 1, .to = 0, .text = "Hi" },
    };
    const art = try layout(arena.allocator(), &parts, &events, false);
    try std.testing.expect(std.mem.indexOf(u8, art, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "Bob") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{25B6}") != null); // right arrow ▶
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{25C0}") != null); // left arrow ◀
}

test "sequence draws a self-message as a loop with its text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parts = [_]Participant{ .{ .display = "A" }, .{ .display = "B" } };
    const events = [_]Event{
        .{ .kind = .msg, .from = 0, .to = 1, .text = "ask" },
        .{ .kind = .msg, .from = 1, .to = 1, .text = "retry" },
    };
    const art = try layout(arena.allocator(), &parts, &events, false);
    try std.testing.expect(std.mem.indexOf(u8, art, "retry") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{25C0}") != null); // loop re-enters the lifeline ◀
}

test "sequence draws a loop frame, a note and an activation bar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parts = [_]Participant{ .{ .display = "A" }, .{ .display = "B" } };
    const events = [_]Event{
        .{ .kind = .frag_open, .label = "loop every minute" },
        .{ .kind = .msg, .from = 0, .to = 1, .text = "ping" },
        .{ .kind = .activate, .who = 1 },
        .{ .kind = .note, .a = 1, .b = 1, .text = "thinking" },
        .{ .kind = .msg, .from = 1, .to = 0, .text = "pong" },
        .{ .kind = .deactivate, .who = 1 },
        .{ .kind = .frag_close },
    };
    const art = try layout(arena.allocator(), &parts, &events, false);
    try std.testing.expect(std.mem.indexOf(u8, art, "loop") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "minute") != null); // frame label word
    try std.testing.expect(std.mem.indexOf(u8, art, "thinking") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{2503}") != null); // activation bar ┃
}

test "fragOpenKeyword matches a fragment keyword as a whole word" {
    try std.testing.expectEqualStrings("loop retry", fragOpenKeyword("loop retry").?);
    try std.testing.expectEqualStrings("alt", fragOpenKeyword("alt").?);
    try std.testing.expect(fragOpenKeyword("looping") == null);
}

test "parseNote handles over with two participants and single-sided notes" {
    const o = parseNote("note over A,B: hi").?;
    try std.testing.expectEqualStrings("A", o.a);
    try std.testing.expectEqualStrings("B", o.b);
    try std.testing.expectEqualStrings("hi", o.text);
    const l = parseNote("note left of X: msg").?;
    try std.testing.expectEqualStrings("X", l.a);
    try std.testing.expectEqualStrings("X", l.b);
}

test "parseMessage reads endpoints, text and activation suffixes" {
    const m = parseMessage("Alice->>Bob: hi").?;
    try std.testing.expectEqualStrings("Alice", m.from);
    try std.testing.expectEqualStrings("Bob", m.to);
    try std.testing.expectEqualStrings("hi", m.text);
    try std.testing.expect(!m.act_target and !m.deact_source);
    const a = parseMessage("Alice->>+Bob: go").?;
    try std.testing.expect(a.act_target);
    try std.testing.expectEqualStrings("Bob", a.to);
    const d = parseMessage("Alice-->>-Bob: bye").?;
    try std.testing.expect(d.deact_source);
    try std.testing.expect(parseMessage("Alice and Bob talk") == null);
}
