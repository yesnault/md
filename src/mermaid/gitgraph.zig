//! Syntax Ref: https://mermaid.ai/open-source/syntax/gitgraph.html
//!
//! Time flows left to right, one column per commit. Each branch owns a row.
//! Scope: commit/branch/checkout/switch/merge with id/tag, plus cherry-pick as a
//! hollow dot. Per-commit `type` styling beyond HIGHLIGHT is not drawn.

const std = @import("std");
const Canvas = @import("canvas.zig").Canvas;
const width = @import("../markdown/width.zig");
const text = @import("text.zig");

const ws = text.ws;

const col_gap: usize = 4;
const row_gap: usize = 2;

const Branch = struct {
    name: []const u8,
    lane: usize,
    last_col: i64 = -1,
    min_col: i64 = -1,
    max_col: i64 = -1,
};
const Commit = struct { col: usize, lane: usize, label: []const u8, highlight: bool, cherry: bool = false };
const Riser = struct { col: usize, lane_a: usize, lane_b: usize };

pub fn render(arena: std.mem.Allocator, src: []const u8, ascii: bool) ![]const u8 {
    var branches: std.ArrayList(Branch) = .empty;
    var index: std.StringHashMap(usize) = .init(arena);
    var commits: std.ArrayList(Commit) = .empty;
    var risers: std.ArrayList(Riser) = .empty;

    try branches.append(arena, .{ .name = "main", .lane = 0 });
    try index.put("main", 0);
    var cur: usize = 0;
    var next_col: usize = 0;

    var it = text.BodyLines.init(src); // skips the header line, blanks, %%
    while (it.next()) |ln| {
        const t = ln.text;

        if (std.mem.eql(u8, t, "commit") or std.mem.startsWith(u8, t, "commit ")) {
            const col = next_col;
            next_col += 1;
            const label = optValue(t, "tag:") orelse optValue(t, "id:") orelse "";
            try commits.append(arena, .{ .col = col, .lane = branches.items[cur].lane, .label = label, .highlight = std.mem.indexOf(u8, t, "HIGHLIGHT") != null });
            touch(&branches.items[cur], col);
            continue;
        }
        if (std.mem.startsWith(u8, t, "branch ")) {
            const name = firstToken(t[7..]);
            if (name.len == 0 or index.contains(name)) {
                if (index.get(name)) |bi| cur = bi;
                continue;
            }
            const parent_col: usize = if (branches.items[cur].last_col < 0) 0 else @intCast(branches.items[cur].last_col);
            const lane = branches.items.len;
            const pc: i64 = @intCast(parent_col);
            try branches.append(arena, .{ .name = name, .lane = lane, .last_col = pc, .min_col = pc, .max_col = pc });
            try index.put(name, lane);
            try risers.append(arena, .{ .col = parent_col, .lane_a = branches.items[cur].lane, .lane_b = lane });
            cur = lane; // mermaid `branch` also checks out the new branch
            continue;
        }
        if (std.mem.startsWith(u8, t, "checkout ") or std.mem.startsWith(u8, t, "switch ")) {
            const arg = if (std.mem.startsWith(u8, t, "checkout ")) t["checkout ".len..] else t["switch ".len..];
            const name = firstToken(arg);
            if (index.get(name)) |bi| cur = bi;
            continue;
        }
        if (std.mem.startsWith(u8, t, "merge ")) {
            const name = firstToken(t[6..]);
            const si = index.get(name) orelse continue;
            const col = next_col;
            next_col += 1;
            const label = optValue(t, "tag:") orelse optValue(t, "id:") orelse "";
            try commits.append(arena, .{ .col = col, .lane = branches.items[cur].lane, .label = label, .highlight = false });
            try risers.append(arena, .{ .col = col, .lane_a = branches.items[si].lane, .lane_b = branches.items[cur].lane });
            touch(&branches.items[cur], col);
            const c: i64 = @intCast(col);
            if (c > branches.items[si].max_col) branches.items[si].max_col = c;
            continue;
        }
        if (std.mem.startsWith(u8, t, "cherry-pick")) {
            // A new commit on the current branch, labelled with the picked id
            // (or its own tag when given).
            const id = optValue(t, "id:") orelse continue;
            const col = next_col;
            next_col += 1;
            const label = optValue(t, "tag:") orelse id;
            try commits.append(arena, .{ .col = col, .lane = branches.items[cur].lane, .label = label, .highlight = false, .cherry = true });
            touch(&branches.items[cur], col);
            continue;
        }
        // Anything else (per-commit type styling, ...): not drawn.
    }
    if (commits.items.len == 0) return error.Empty;

    var max_name: usize = 1;
    for (branches.items) |b| max_name = @max(max_name, width.displayWidth(b.name));
    const left = max_name + 2;
    const nlanes = branches.items.len;
    const w = left + next_col * col_gap + 10;
    const h = 2 * nlanes + 1;
    const xcol = struct {
        fn f(l: usize, col: usize) usize {
            return l + col * col_gap;
        }
    }.f;
    const yrow = struct {
        fn f(lane: usize) usize {
            return 1 + lane * row_gap;
        }
    }.f;

    var c = try Canvas.init(arena, w, h);
    // Lane lines + branch names.
    for (branches.items) |b| {
        const row = yrow(b.lane);
        if (b.name.len > 0) c.putStr(0, row, clip(b.name, left - 1));
        if (b.max_col > b.min_col and b.min_col >= 0) {
            c.lineH(xcol(left, @intCast(b.min_col)), xcol(left, @intCast(b.max_col)), row);
        }
    }
    // Risers (branch points and merges).
    for (risers.items) |r| c.lineV(yrow(r.lane_a), yrow(r.lane_b), xcol(left, r.col));
    // Commit dots + labels (dots override the line layer at their cell).
    const dot: u21 = if (ascii) '*' else '\u{25CF}'; // ●
    const hot: u21 = if (ascii) '#' else '\u{25C9}'; // ◉
    const pick: u21 = if (ascii) 'o' else '\u{25CB}'; // ○
    for (commits.items) |cm| {
        const cx = xcol(left, cm.col);
        const row = yrow(cm.lane);
        c.set(cx, row, if (cm.highlight) hot else if (cm.cherry) pick else dot);
        if (cm.label.len > 0 and row > 0) c.putStr(cx, row - 1, clip(cm.label, 9));
    }
    return c.toString(ascii);
}

fn touch(b: *Branch, col: usize) void {
    const c: i64 = @intCast(col);
    b.last_col = c;
    if (b.min_col < 0 or c < b.min_col) b.min_col = c;
    if (c > b.max_col) b.max_col = c;
}

fn optValue(line: []const u8, key: []const u8) ?[]const u8 {
    const i = std.mem.indexOf(u8, line, key) orelse return null;
    const rest = std.mem.trim(u8, line[i + key.len ..], ws);
    if (rest.len == 0) return null;
    if (rest[0] == '"') {
        const e = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return rest[1..];
        return rest[1..e];
    }
    const e = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
    return rest[0..e];
}

const firstToken = text.firstWord;

const clip = text.clip;

test "gitGraph renders branch lanes, commits, a branch riser and a merge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "gitGraph\n" ++
        "commit\n" ++
        "commit id: \"start\"\n" ++
        "branch develop\n" ++
        "checkout develop\n" ++
        "commit\n" ++
        "checkout main\n" ++
        "merge develop tag: \"v1.0\"\n" ++
        "commit\n";
    const art = try render(arena.allocator(), src, false);
    for ([_][]const u8{ "main", "develop", "start", "v1.0" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, art, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{25CF}") != null); // commit dot ●
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{2502}") != null); // a riser segment │
}

test "gitGraph cherry-pick draws a hollow dot labelled with the picked id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "gitGraph\n" ++
        "commit\n" ++
        "branch develop\n" ++
        "commit id: \"hotfix\"\n" ++
        "checkout main\n" ++
        "cherry-pick id: \"hotfix\"\n";
    const art = try render(arena.allocator(), src, false);
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{25CB}") != null); // hollow pick dot ○
    try std.testing.expect(std.mem.indexOf(u8, art, "hotfix") != null);

    const ascii_art = try render(arena.allocator(), src, true);
    try std.testing.expect(std.mem.indexOf(u8, ascii_art, "o") != null);
}

test "gitGraph ascii mode and HIGHLIGHT commit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "gitGraph\n" ++
        "commit\n" ++
        "commit type: HIGHLIGHT\n";
    const art = try render(arena.allocator(), src, true);
    try std.testing.expect(std.mem.indexOf(u8, art, "*") != null); // ascii dot
    try std.testing.expect(std.mem.indexOf(u8, art, "#") != null); // ascii highlight dot
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{25CF}") == null); // ●
}
