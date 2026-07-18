//! Syntax Ref: https://mermaid.ai/open-source/syntax/gantt.html
//!
//! A time-scaled bar chart. `dateFormat YYYY-MM-DD` is the only format parsed. A task start is a date,
//! `after <id>`, or implicit (the previous task's end).

const std = @import("std");
const width = @import("../markdown/width.zig");
const text = @import("text.zig");

// Wall-clock seconds since the Unix epoch (libc is linked). Used for the gantt
// "today" marker, since std.time has no wall-clock helper in this Zig version.
extern "c" fn time(tloc: ?*c_long) c_long;

const ws = text.ws;
const track_w: usize = 40; // timeline columns

const Task = struct {
    label: []const u8,
    section: usize,
    id: []const u8 = "",
    after: []const u8 = "", // space-separated dep ids, "" = none
    has_start: bool = false,
    start: f64 = 0, // day number
    dur: f64 = 1, // days
    dur_str: []const u8 = "", // authored duration token (e.g. "8h"), for the label
    end: f64 = 0, // day number (working-day aware when excludes apply)
    milestone: bool = false,
    resolved: bool = false,
};

const Excludes = struct { weekends: bool, set: *std.AutoHashMap(i64, void) };

pub fn render(arena: std.mem.Allocator, src: []const u8, ascii: bool) ![]const u8 {
    var title: []const u8 = "";
    var sections: std.ArrayList([]const u8) = .empty;
    try sections.append(arena, ""); // section 0 = no header
    var cur_section: usize = 0;
    var tasks: std.ArrayList(Task) = .empty;
    var excl_weekends = false;
    var excl_set: std.AutoHashMap(i64, void) = .init(arena);
    var show_today = true;

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
        if (std.mem.startsWith(u8, t, "excludes")) {
            var xit = std.mem.tokenizeAny(u8, t["excludes".len..], " \t,");
            while (xit.next()) |tok| {
                if (std.mem.eql(u8, tok, "weekends")) excl_weekends = true else if (parseDate(tok)) |d| try excl_set.put(d, {});
            }
            continue;
        }
        if (std.mem.startsWith(u8, t, "todayMarker")) {
            if (std.mem.indexOf(u8, t, "off") != null) show_today = false;
            continue;
        }
        // Other directives we accept but don't render.
        if (startsWithAny(t, &.{ "dateFormat", "axisFormat", "includes", "tickInterval", "weekday" })) continue;
        // Task: "Label : spec".
        const colon = std.mem.indexOfScalar(u8, t, ':') orelse continue;
        const label = std.mem.trim(u8, t[0..colon], ws);
        if (label.len == 0) continue;
        var task = Task{ .label = label, .section = cur_section };
        parseSpec(std.mem.trim(u8, t[colon + 1 ..], ws), &task);
        try tasks.append(arena, task);
    }
    if (tasks.items.len == 0) return error.NoTasks;

    // Index tasks that declare an id, for `after` resolution.
    var by_id: std.StringHashMap(usize) = .init(arena);
    for (tasks.items, 0..) |tk, i| {
        if (tk.id.len > 0) try by_id.put(tk.id, i);
    }
    const ex = Excludes{ .weekends = excl_weekends, .set = &excl_set };
    resolveStarts(tasks.items, by_id, ex);

    // Timeline bounds over resolved tasks.
    var min_day: f64 = std.math.floatMax(f64);
    var max_day: f64 = -std.math.floatMax(f64);
    for (tasks.items) |tk| {
        if (!tk.resolved) continue;
        min_day = @min(min_day, tk.start);
        max_day = @max(max_day, tk.end);
    }
    if (min_day > max_day) return error.NoTasks;
    const span = @max(max_day - min_day, 1);

    // "Today" marker column, if today falls within the timeline.
    const today: f64 = @floatFromInt(@divFloor(@as(i64, @intCast(time(null))), 86400));
    // scale can return track_w (one past the last drawn column): clamp so a
    // today at the very end of the range still renders.
    const today_col: ?usize = if (show_today and today >= min_day and today <= max_day)
        @min(scale(today - min_day, span), track_w - 1)
    else
        null;
    const marker: []const u8 = if (ascii) ":" else "\u{250A}"; // ┊

    var max_label: usize = 0;
    for (tasks.items) |tk| max_label = @max(max_label, width.displayWidth(tk.label));

    const fill: []const u8 = if (ascii) "#" else "\u{2588}"; // █
    const dot: []const u8 = if (ascii) "." else "\u{2591}"; // ░
    const diamond: []const u8 = if (ascii) "*" else "\u{25C6}"; // ◆

    var out: std.ArrayList(u8) = .empty;
    if (title.len > 0) {
        try out.appendSlice(arena, title);
        try out.appendSlice(arena, "\n\n");
    }
    // Axis header: start date at the left of the track, end date at the right.
    {
        try appendSpaces(&out, arena, max_label + 3);
        const lo = try fmtDate(arena, @intFromFloat(@floor(min_day)));
        const hi = try fmtDate(arena, @intFromFloat(@floor(max_day)));
        try out.appendSlice(arena, lo);
        const used = lo.len + hi.len;
        try appendSpaces(&out, arena, if (track_w > used) track_w - used else 1);
        try out.appendSlice(arena, hi);
        try out.append(arena, '\n');
    }

    var last_section: usize = std.math.maxInt(usize);
    for (tasks.items) |tk| {
        if (!tk.resolved) continue;
        if (tk.section != last_section) {
            last_section = tk.section;
            if (sections.items[tk.section].len > 0) {
                try out.appendSlice(arena, sections.items[tk.section]);
                try out.append(arena, '\n');
            }
        }
        try out.appendSlice(arena, "  ");
        try out.appendSlice(arena, tk.label);
        try appendSpaces(&out, arena, max_label - width.displayWidth(tk.label) + 1);

        // Track with the task span filled in (today marker drawn over it).
        const s_off = scale(tk.start - min_day, span);
        var e_off = scale(tk.end - min_day, span);
        if (!tk.milestone and e_off <= s_off) e_off = s_off + 1;
        var col: usize = 0;
        while (col < track_w) : (col += 1) {
            if (today_col != null and col == today_col.?) {
                try out.appendSlice(arena, marker);
            } else if (tk.milestone) {
                try out.appendSlice(arena, if (col == @min(s_off, track_w - 1)) diamond else dot);
            } else {
                try out.appendSlice(arena, if (col >= s_off and col < e_off) fill else dot);
            }
        }

        const date = try fmtDate(arena, @intFromFloat(@floor(tk.start)));
        const tail = if (tk.milestone)
            try std.fmt.allocPrint(arena, "  {s} {s}\n", .{ date, diamond })
        else
            try std.fmt.allocPrint(arena, "  {s} ({s})\n", .{ date, if (tk.dur_str.len > 0) tk.dur_str else "1d" });
        try out.appendSlice(arena, tail);
    }
    return std.mem.trimEnd(u8, out.items, "\n");
}

fn scale(day_off: f64, span: f64) usize {
    const c: f64 = day_off / span * @as(f64, @floatFromInt(track_w));
    if (c <= 0) return 0;
    const r: usize = @intFromFloat(@round(c));
    return @min(r, track_w);
}

fn parseSpec(spec: []const u8, task: *Task) void {
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |raw| {
        const tok = std.mem.trim(u8, raw, ws);
        if (tok.len == 0) continue;
        if (eqAny(tok, &.{ "done", "active", "crit" })) continue;
        if (std.mem.eql(u8, tok, "milestone")) {
            task.milestone = true;
            continue;
        }
        if (std.mem.startsWith(u8, tok, "after ")) {
            task.after = std.mem.trim(u8, tok[6..], ws);
            continue;
        }
        if (parseDate(tok)) |d| {
            task.start = @floatFromInt(d);
            task.has_start = true;
            continue;
        }
        if (parseDuration(tok)) |d| {
            task.dur = d;
            task.dur_str = tok;
            continue;
        }
        // First leftover bare token = task id.
        if (task.id.len == 0) task.id = tok;
    }
    if (task.milestone) task.dur = 0;
}

fn isWeekend(day: i64) bool {
    const m = @mod(day, 7); // 1970-01-01 is Thursday (0)
    return m == 2 or m == 3; // Saturday, Sunday
}

fn isExcluded(day: i64, ex: Excludes) bool {
    return (ex.weekends and isWeekend(day)) or ex.set.contains(day);
}

/// The exclusive end day. With excludes in play it advances `dur` working days from
/// `start`. Without, it is start + dur.
fn computeEnd(start: f64, dur: f64, ex: Excludes) f64 {
    if (dur < 1 or (!ex.weekends and ex.set.count() == 0)) return start + dur;
    var d: i64 = @intFromFloat(@floor(start));
    var c: i64 = @intFromFloat(@round(dur));
    while (c > 0) {
        if (!isExcluded(d, ex)) c -= 1;
        d += 1;
    }
    return @floatFromInt(d);
}

/// Explicit dates first, then `after` dependencies (max end of the referenced
/// tasks), then implicit sequential (previous task's end). Iterates to a fixed point
/// so a forward `after` reference still resolves. Tasks whose deps never resolve are
/// skipped.
fn resolveStarts(tasks: []Task, by_id: std.StringHashMap(usize), ex: Excludes) void {
    for (tasks) |*tk| {
        if (tk.has_start) {
            tk.resolved = true;
            tk.end = computeEnd(tk.start, tk.dur, ex);
        }
    }
    var pass: usize = 0;
    while (pass <= tasks.len) : (pass += 1) {
        var changed = false;
        for (tasks, 0..) |*tk, i| {
            if (tk.resolved) continue;
            if (tk.after.len > 0) {
                var end: f64 = 0;
                var ok = true;
                var dep_it = std.mem.tokenizeAny(u8, tk.after, " \t");
                while (dep_it.next()) |dep| {
                    const di = by_id.get(dep) orelse {
                        ok = false;
                        break;
                    };
                    if (!tasks[di].resolved) {
                        ok = false;
                        break;
                    }
                    end = @max(end, tasks[di].end);
                }
                if (ok) {
                    tk.start = end;
                    tk.resolved = true;
                    tk.end = computeEnd(tk.start, tk.dur, ex);
                    changed = true;
                }
            } else if (i > 0 and tasks[i - 1].resolved) {
                tk.start = tasks[i - 1].end;
                tk.resolved = true;
                tk.end = computeEnd(tk.start, tk.dur, ex);
                changed = true;
            } else if (i == 0) {
                tk.start = 0;
                tk.resolved = true;
                tk.end = computeEnd(tk.start, tk.dur, ex);
                changed = true;
            }
        }
        if (!changed) break;
    }
}

fn parseDuration(tok: []const u8) ?f64 {
    if (tok.len < 2) return null;
    const unit = tok[tok.len - 1];
    const mult: f64 = switch (unit) {
        'd' => 1,
        'w' => 7,
        'h' => 1.0 / 24.0,
        'm' => 1.0 / 1440.0,
        's' => 1.0 / 86400.0,
        else => return null,
    };
    const n = std.fmt.parseFloat(f64, tok[0 .. tok.len - 1]) catch return null;
    return n * mult;
}

fn parseDate(tok: []const u8) ?i64 {
    if (tok.len != 10 or tok[4] != '-' or tok[7] != '-') return null;
    const y = std.fmt.parseInt(i64, tok[0..4], 10) catch return null;
    const m = std.fmt.parseInt(i64, tok[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, tok[8..10], 10) catch return null;
    if (m < 1 or m > 12 or d < 1 or d > 31) return null;
    return daysFromCivil(y, m, d);
}

fn fmtDate(arena: std.mem.Allocator, day: i64) ![]const u8 {
    const c = civilFromDays(day);
    // Cast to unsigned: a '0' fill on signed integers triggers sign output ("+2014").
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u32, @intCast(@max(c.y, 0))), @as(u8, @intCast(c.m)), @as(u8, @intCast(c.d)),
    });
}

// Howard Hinnant's civil<->days algorithms (days since 1970-01-01).
fn daysFromCivil(y0: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const Civil = struct { y: i64, m: i64, d: i64 };

fn civilFromDays(z0: i64) Civil {
    const z = z0 + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = if (m <= 2) y + 1 else y, .m = m, .d = d };
}

fn startsWithAny(t: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| if (std.mem.startsWith(u8, t, p)) return true;
    return false;
}

fn eqAny(t: []const u8, opts: []const []const u8) bool {
    for (opts) |o| if (std.mem.eql(u8, t, o)) return true;
    return false;
}

const appendSpaces = text.appendSpaces;

test "gantt scales tasks across a timeline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "gantt\n" ++
        "title A Gantt Diagram\n" ++
        "dateFormat YYYY-MM-DD\n" ++
        "section Phase\n" ++
        "  A task     :a1, 2014-01-01, 30d\n" ++
        "  Another    :after a1, 20d\n";
    const art = try render(arena.allocator(), src, true);
    try std.testing.expect(std.mem.indexOf(u8, art, "A Gantt Diagram") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "Phase") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "2014-01-01") != null);
    // The second task starts after the first ends (2014-01-31).
    try std.testing.expect(std.mem.indexOf(u8, art, "2014-01-31") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "#") != null); // ascii fill
}

test "gantt date arithmetic round-trips" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    const c = civilFromDays(daysFromCivil(2014, 1, 31));
    try std.testing.expectEqual(@as(i64, 2014), c.y);
    try std.testing.expectEqual(@as(i64, 1), c.m);
    try std.testing.expectEqual(@as(i64, 31), c.d);
}

test "gantt excludes weekends pushes the end past the weekend" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // 2014-01-03 is a Friday. A 2-day task skips Sat/Sun and ends Tue 2014-01-07.
    const src =
        "gantt\n" ++
        "dateFormat YYYY-MM-DD\n" ++
        "excludes weekends\n" ++
        "section S\n" ++
        "  t :2014-01-03, 2d\n";
    const art = try render(arena.allocator(), src, true);
    try std.testing.expect(std.mem.indexOf(u8, art, "2014-01-07") != null);
}

test "gantt labels sub-day durations with their unit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "gantt\ndateFormat YYYY-MM-DD\nsection S\n  t :2014-01-01, 8h\n";
    const art = try render(arena.allocator(), src, true);
    try std.testing.expect(std.mem.indexOf(u8, art, "(8h)") != null);
}

test "parseDuration converts unit suffixes to days" {
    try std.testing.expectEqual(@as(?f64, 2), parseDuration("2d"));
    try std.testing.expectEqual(@as(?f64, 21), parseDuration("3w"));
    try std.testing.expectEqual(@as(?f64, null), parseDuration("x")); // too short
    try std.testing.expectEqual(@as(?f64, null), parseDuration("5y")); // unknown unit
}

test "parseDate reads YYYY-MM-DD, rejecting malformed dates" {
    try std.testing.expectEqual(@as(?i64, 0), parseDate("1970-01-01")); // epoch = day 0
    try std.testing.expectEqual(@as(?i64, 1), parseDate("1970-01-02"));
    try std.testing.expectEqual(@as(?i64, null), parseDate("2014-13-01")); // month > 12
    try std.testing.expectEqual(@as(?i64, null), parseDate("2014-01-32")); // day > 31
    try std.testing.expectEqual(@as(?i64, null), parseDate("not-a-date"));
}
