//! Syntax Ref: https://mermaid.ai/open-source/syntax/timeline.html
//!
//! A vertical list: section headers, then one row per period with its events
//! branched off to the right.

const std = @import("std");
const width = @import("../markdown/width.zig");
const text = @import("text.zig");

const ws = text.ws;

const Period = struct {
    label: []const u8,
    section: usize,
    events: std.ArrayList([]const u8) = .empty,
};

const Glyphs = struct {
    single: []const u8, // period with one event
    branch: []const u8, // first of several events
    mid: []const u8, // middle event (continuation line)
    last: []const u8, // last event (continuation line)
};
const unicode = Glyphs{ .single = "\u{2500}\u{2500}\u{2500} ", .branch = "\u{2500}\u{252C}\u{2500} ", .mid = "\u{251C}\u{2500} ", .last = "\u{2514}\u{2500} " }; // ─── ─┬─ ├─ └─
const ascii = Glyphs{ .single = "--- ", .branch = "-+- ", .mid = "|- ", .last = "`- " };

pub fn render(arena: std.mem.Allocator, src: []const u8, ascii_mode: bool) ![]const u8 {
    var title: []const u8 = "";
    var sections: std.ArrayList([]const u8) = .empty;
    try sections.append(arena, ""); // section 0 = no header
    var cur_section: usize = 0;
    var periods: std.ArrayList(Period) = .empty;
    var max_period_w: usize = 0;

    var it = text.BodyLines.init(src); // skips the header line, blanks, %%
    while (it.next()) |ln| {
        const t = ln.text;
        if (std.mem.startsWith(u8, t, "title ")) {
            title = std.mem.trim(u8, t[6..], ws);
            continue;
        }
        if (std.mem.startsWith(u8, t, "section ")) {
            try sections.append(arena, std.mem.trim(u8, t[8..], ws));
            cur_section = sections.items.len - 1;
            continue;
        }
        // Continuation line ": event [: event ...]" → more events on the last period.
        if (t[0] == ':') {
            if (periods.items.len == 0) continue;
            try appendEvents(arena, &periods.items[periods.items.len - 1].events, t[1..]);
            continue;
        }
        // Period line "label : event [: event ...]" (or a bare label, no colon).
        const colon = std.mem.indexOfScalar(u8, t, ':');
        const label = std.mem.trim(u8, if (colon) |c| t[0..c] else t, ws);
        var p: Period = .{ .label = label, .section = cur_section };
        if (colon) |c| try appendEvents(arena, &p.events, t[c + 1 ..]);
        try periods.append(arena, p);
        max_period_w = @max(max_period_w, width.displayWidth(label));
    }
    if (periods.items.len == 0) return error.Empty;

    const g = if (ascii_mode) ascii else unicode;
    var out: std.ArrayList(u8) = .empty;
    if (title.len > 0) {
        try out.appendSlice(arena, title);
        try out.appendSlice(arena, "\n\n");
    }
    const cont_pad = 2 + max_period_w + 2; // align ├/└ under the branch ┬
    var last_section: usize = std.math.maxInt(usize);
    for (periods.items) |p| {
        if (p.section != last_section) {
            last_section = p.section;
            if (sections.items[p.section].len > 0) {
                try out.appendSlice(arena, sections.items[p.section]);
                try out.append(arena, '\n');
            }
        }
        try out.appendSlice(arena, "  ");
        try out.appendSlice(arena, p.label);
        try text.appendSpaces(&out, arena, max_period_w - width.displayWidth(p.label) + 1);
        const evs = p.events.items;
        if (evs.len == 0) {
            try out.append(arena, '\n');
            continue;
        }
        try out.appendSlice(arena, if (evs.len == 1) g.single else g.branch);
        try out.appendSlice(arena, evs[0]);
        try out.append(arena, '\n');
        for (evs[1..], 1..) |ev, i| {
            try text.appendSpaces(&out, arena, cont_pad);
            try out.appendSlice(arena, if (i == evs.len - 1) g.last else g.mid);
            try out.appendSlice(arena, ev);
            try out.append(arena, '\n');
        }
    }
    return std.mem.trimEnd(u8, out.items, "\n");
}

fn appendEvents(arena: std.mem.Allocator, events: *std.ArrayList([]const u8), s: []const u8) !void {
    var it = std.mem.splitScalar(u8, s, ':');
    while (it.next()) |part| {
        const ev = try cleanBr(arena, std.mem.trim(u8, part, ws));
        if (ev.len > 0) try events.append(arena, ev);
    }
}

fn cleanBr(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, s, "<br") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (i + 3 <= s.len and s[i] == '<' and std.ascii.eqlIgnoreCase(s[i .. i + 3], "<br")) {
            const gt = std.mem.indexOfScalarPos(u8, s, i, '>') orelse {
                try out.append(arena, s[i]);
                i += 1;
                continue;
            };
            try out.append(arena, ' ');
            i = gt + 1;
        } else {
            try out.append(arena, s[i]);
            i += 1;
        }
    }
    return std.mem.trim(u8, out.items, ws);
}



test "timeline renders title, sections and branched events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "timeline\n" ++
        "title History of Social Media\n" ++
        "section 2000s\n" ++
        "  2002 : LinkedIn : MySpace\n" ++
        "  2004 : Facebook\n" ++
        "section 2010s\n" ++
        "  2011 : Snapchat\n";
    const art = try render(arena.allocator(), src, false);
    for ([_][]const u8{ "History of Social Media", "2000s", "2010s", "LinkedIn", "MySpace", "Facebook", "Snapchat" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, art, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{252C}") != null); // branch ┬
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{2514}") != null); // last └
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{2500}\u{2500}\u{2500}") != null); // single ───
}

test "timeline ascii mode, continuation lines and <br>" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "timeline\n" ++
        "  2004 : Facebook\n" ++
        "       : Google<br/>Inc\n";
    const art = try render(arena.allocator(), src, true);
    try std.testing.expect(std.mem.indexOf(u8, art, "-+-") != null); // ascii branch
    try std.testing.expect(std.mem.indexOf(u8, art, "`-") != null); // ascii last
    try std.testing.expect(std.mem.indexOf(u8, art, "Google Inc") != null); // <br/> → space
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{2500}") == null); // no unicode glyphs ─
}
