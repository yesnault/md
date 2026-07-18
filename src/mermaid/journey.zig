//! Syntax Ref: https://mermaid.ai/open-source/syntax/userJourney.html
//!
//! Tasks scored 1-5, grouped by section.

const std = @import("std");
const width = @import("../markdown/width.zig");
const text = @import("text.zig");

const ws = text.ws;
const appendSpaces = text.appendSpaces;

pub fn render(arena: std.mem.Allocator, src: []const u8, ascii: bool) ![]const u8 {
    const Task = struct { label: []const u8, score: u8, actors: []const u8, section: usize };
    var title: []const u8 = "";
    var sections: std.ArrayList([]const u8) = .empty;
    try sections.append(arena, ""); // section 0 = no header
    var cur: usize = 0;
    var tasks: std.ArrayList(Task) = .empty;
    var max_label: usize = 0;

    var it = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, ws);
        if (first) {
            first = false;
            continue; // skip "journey"
        }
        if (t.len == 0 or std.mem.startsWith(u8, t, "%%")) continue;
        if (std.mem.startsWith(u8, t, "title ")) {
            title = std.mem.trim(u8, t[6..], ws);
            continue;
        }
        if (std.mem.startsWith(u8, t, "section ")) {
            try sections.append(arena, std.mem.trim(u8, t[8..], ws));
            cur = sections.items.len - 1;
            continue;
        }
        // Task: "Label: score: actor1, actor2".
        const c1 = std.mem.indexOfScalar(u8, t, ':') orelse continue;
        const label = std.mem.trim(u8, t[0..c1], ws);
        var rest = std.mem.trim(u8, t[c1 + 1 ..], ws);
        var actors: []const u8 = "";
        if (std.mem.indexOfScalar(u8, rest, ':')) |c2| {
            actors = std.mem.trim(u8, rest[c2 + 1 ..], ws);
            rest = std.mem.trim(u8, rest[0..c2], ws);
        }
        const score = std.fmt.parseInt(u8, rest, 10) catch continue;
        try tasks.append(arena, .{ .label = label, .score = score, .actors = actors, .section = cur });
        max_label = @max(max_label, width.displayWidth(label));
    }
    if (tasks.items.len == 0) return error.NoTasks;

    const full: []const u8 = if (ascii) "#" else "\u{2605}"; // ★
    const empty: []const u8 = if (ascii) "-" else "\u{2606}"; // ☆

    var out: std.ArrayList(u8) = .empty;
    if (title.len > 0) {
        try out.appendSlice(arena, title);
        try out.appendSlice(arena, "\n\n");
    }
    var last_section: usize = std.math.maxInt(usize);
    for (tasks.items) |tk| {
        if (tk.section != last_section) {
            last_section = tk.section;
            if (sections.items[tk.section].len > 0) {
                try out.appendSlice(arena, sections.items[tk.section]);
                try out.append(arena, '\n');
            }
        }
        try out.appendSlice(arena, "  ");
        try out.appendSlice(arena, tk.label);
        try appendSpaces(&out, arena, max_label - width.displayWidth(tk.label) + 2);
        const s: u8 = @min(tk.score, 5);
        var k: u8 = 0;
        while (k < 5) : (k += 1) try out.appendSlice(arena, if (k < s) full else empty);
        const tail = try std.fmt.allocPrint(arena, "  ({d})  {s}\n", .{ tk.score, tk.actors });
        try out.appendSlice(arena, tail);
    }
    return std.mem.trimEnd(u8, out.items, "\n");
}
