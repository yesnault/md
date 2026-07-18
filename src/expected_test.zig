//! Expected-output tests: render every fixture in tests/*.md deterministically
//! (width 80, notty theme, no SGR) and compare against tests/expected/<name>.txt.
//!
//! Regenerate them after an intended rendering change, with:
//!   zig build test -Dupdate-expected

const std = @import("std");
const Io = std.Io;
const render = @import("render.zig");
const options = @import("options.zig");

const fixture_dir = "tests";
const expected_dir = "tests/expected";
const render_opts: options.Options = .{ .width = 80, .style = "notty" };

test "expected: every tests/*.md fixture matches tests/expected/<name>.txt" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const update = std.c.getenv("UPDATE_EXPECTED") != null;
    if (update) try Io.Dir.cwd().createDirPath(io, expected_dir);

    var dir = try Io.Dir.cwd().openDir(io, fixture_dir, .{ .iterate = true });
    defer dir.close(io);

    // Collect and sort fixture names so failures are reported in a stable order.
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        if (std.mem.eql(u8, entry.name, "README.md")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    try std.testing.expect(names.items.len > 0);

    for (names.items) |name| {
        const src = try dir.readFileAlloc(io, name, arena, .unlimited);
        var opts = render_opts;
        // wikilink* fixtures exercise the opt-in wikilinks extension.
        if (std.mem.startsWith(u8, name, "wikilink")) opts.wikilinks = true;
        const got = try render.renderToAnsi(arena, src, opts);
        const stem = name[0 .. name.len - ".md".len];
        const expected_path = try std.fmt.allocPrint(arena, "{s}/{s}.txt", .{ expected_dir, stem });

        if (update) {
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = expected_path, .data = got });
            continue;
        }
        const want = Io.Dir.cwd().readFileAlloc(io, expected_path, arena, .unlimited) catch |err| {
            std.debug.print(
                "expected: missing {s} for fixture {s} ({t}); run zig build test -Dupdate-expected\n",
                .{ expected_path, name, err },
            );
            return error.MissingExpected;
        };
        std.testing.expectEqualStrings(want, got) catch |err| {
            std.debug.print(
                "expected: fixture {s} differs from {s}; if intended, run zig build test -Dupdate-expected\n",
                .{ name, expected_path },
            );
            return err;
        };
    }
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
