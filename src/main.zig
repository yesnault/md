//! md: read Markdown in the terminal, with Mermaid diagrams

const std = @import("std");
const Io = std.Io;

const cli = @import("cli.zig");
const render = @import("md");
const options = render.options;
const tui = @import("tui/app.zig");
const wikilink = @import("wikilink.zig");

const usage =
    \\Usage: md [options] [file|-]
    \\
    \\Read Markdown in the terminal, with Mermaid diagrams
    \\
    \\Options:
    \\  -w, --width <n>           word-wrap width (0 = terminal width, capped at 120)
    \\  -s, --style <name>        theme: dark|light|notty (no color) (default: dark)
    \\      --no-tui              force rendering to stdout (no TUI)
    \\      --tui                 force the interactive TUI
    \\      --ascii               render diagrams with ASCII, not Unicode box-drawing
    \\      --wikilinks           render [[target]] / [[target|label]] wiki links
    \\      --graph-dir <LR|TD>   flowchart direction override
    \\      --image               render diagrams as inline images
    \\      --image-protocol <p>  auto|kitty|sixel|halfblocks|none (implies --image)
    \\      --goto-line <n>       TUI: open at the section containing source line n
    \\      --find <text>         TUI: open at the first line containing <text>
    \\  -h, --help                show this help
    \\
    \\With no file and piped stdin, md reads Markdown from stdin.
    \\To pick a file interactively, compose with fzf:  md "$(fzf)"
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const argv = try init.minimal.args.toSlice(arena);
    const args = if (argv.len > 0) argv[1..] else argv;

    var parsed = cli.parse(args) catch |err| {
        try printErr(io, "md: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    if (parsed.help) {
        try writeStdout(io, usage);
        return;
    }

    var env_map = try init.minimal.environ.createMap(arena);

    // Resolve image protocol. "auto" picks Kitty on capable terminals, else
    // half-blocks. Sixel is only used when requested explicitly.
    if (parsed.image) {
        var proto = options.Protocol.parse(parsed.image_protocol);
        if (proto == .auto) proto = if (detectKitty(&env_map)) .kitty else .halfblocks;
        if (proto != .none) {
            parsed.opts.image = true;
            parsed.opts.protocol = proto;
        }
    }

    const path = parsed.path;
    const is_dash = path != null and std.mem.eql(u8, path.?, "-");

    // Explicit stdin, or piped stdin with no path: render to stdout
    if (is_dash) return runCli(io, arena, null, parsed.opts);
    const stdin_tty = Io.File.stdin().isTty(io) catch true;
    if (path == null and !stdin_tty) return runCli(io, arena, null, parsed.opts);

    if (parsed.no_tui) {
        if (path == null) noInput(io);
        return runCli(io, arena, path, parsed.opts);
    }

    const stdout_tty = Io.File.stdout().isTty(io) catch false;
    if (parsed.tui or stdout_tty) {
        if (path == null) noInput(io);
        const data = Io.Dir.cwd().readFileAlloc(io, path.?, arena, .unlimited) catch |err|
            fail(io, "md: cannot read {s}: {s}\n", .{ path.?, @errorName(err) });
        // The TUI re-renders on every resize and frees the previous content
        // it needs a real allocator (the process arena never reclaims).
        tui.run(io, std.heap.c_allocator, &env_map, path.?, data, parsed.opts) catch |err|
            fail(io, "md: tui error: {s}\n", .{@errorName(err)});
        return;
    }

    // Non-interactive and not forced: render a file to stdout
    if (path == null) noInput(io);
    return runCli(io, arena, path, parsed.opts);
}

/// Reads (file or stdin), renders to ANSI, writes stdout. Exits the process with a
/// message on failure.
fn runCli(io: Io, arena: std.mem.Allocator, path: ?[]const u8, opts: options.Options) void {
    if (opts.goto_line != null or opts.find != null)
        printErr(io, "md: --goto-line and --find only apply to the TUI; ignored\n", .{}) catch {};
    const data = readInput(io, arena, path) catch |err| switch (err) {
        error.NoInput => noInput(io),
        else => fail(io, "md: cannot read input: {s}\n", .{@errorName(err)}),
    };
    var o = opts;
    var wl: wikilink.Resolver = .{ .io = io, .dir = "" };
    // Wikilink targets resolve against the document's own directory. stdin has none,
    // so its targets stay unchecked: a cwd has nothing to do with where the Markdown
    // came from.
    if (o.wikilinks) if (path) |p| {
        wl.dir = std.fs.path.dirname(p) orelse ".";
        o.wikilink_check = wl.check();
    };
    const out = render.renderToAnsi(arena, data, o) catch |err|
        fail(io, "md: render failed: {s}\n", .{@errorName(err)});
    writeStdout(io, out) catch |err|
        fail(io, "md: write failed: {s}\n", .{@errorName(err)});
}

fn noInput(io: Io) noreturn {
    fail(io, "md: no input. Give a file or pipe Markdown\n", .{});
}

/// Kitty graphics support, guessed from the environment (Kitty, Ghostty, WezTerm).
fn detectKitty(env: *std.process.Environ.Map) bool {
    if (env.get("KITTY_WINDOW_ID") != null) return true;
    if (env.get("GHOSTTY_RESOURCES_DIR") != null) return true;
    if (env.get("TERM")) |t| {
        if (std.mem.indexOf(u8, t, "kitty") != null) return true;
        if (std.mem.indexOf(u8, t, "ghostty") != null) return true;
    }
    if (env.get("TERM_PROGRAM")) |t| {
        if (std.mem.eql(u8, t, "WezTerm") or std.mem.eql(u8, t, "ghostty")) return true;
    }
    return false;
}

fn fail(io: Io, comptime fmt: []const u8, args: anytype) noreturn {
    printErr(io, fmt, args) catch {};
    std.process.exit(1);
}

/// From a file, or from stdin when `path` is null or "-". NoInput when stdin would
/// be an interactive tty.
fn readInput(io: Io, alloc: std.mem.Allocator, path: ?[]const u8) ![]u8 {
    const from_stdin = path == null or std.mem.eql(u8, path.?, "-");
    if (from_stdin) {
        if (try Io.File.stdin().isTty(io)) return error.NoInput;
        var buf: [4096]u8 = undefined;
        var reader = Io.File.stdin().readerStreaming(io, &buf);
        return reader.interface.allocRemaining(alloc, .unlimited);
    }
    return Io.Dir.cwd().readFileAlloc(io, path.?, alloc, .unlimited);
}

fn writeStdout(io: Io, bytes: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var fw: Io.File.Writer = .init(.stdout(), io, &buf);
    const w = &fw.interface;
    try w.writeAll(bytes);
    try w.flush();
}

fn printErr(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    var fw: Io.File.Writer = .init(.stderr(), io, &buf);
    const w = &fw.interface;
    try w.print(fmt, args);
    try w.flush();
}

test {
    _ = @import("cli.zig");
    _ = @import("wikilink.zig");
    _ = @import("tui/app.zig");
    _ = @import("tui/pager.zig");
    _ = @import("tui/search.zig");
}
