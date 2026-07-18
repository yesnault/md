//! Command-line parsing for `md`.
//!
//! Arguments are the arguments without argv[0].

const std = @import("std");
const options = @import("md").options;
const Options = options.Options;

pub const Parsed = struct {
    /// File path, "-" for stdin, or null when no positional (file path) was given.
    path: ?[]const u8 = null,
    no_tui: bool = false,
    tui: bool = false,
    image: bool = false,
    image_protocol: []const u8 = "auto",
    help: bool = false,
    opts: Options = .{},
};

pub const Error = error{ MissingValue, UnknownFlag, BadWidth, BadStyle, BadGraphDir, BadProtocol, BadLine, TooManyArgs };

pub fn parse(args: []const [:0]const u8) Error!Parsed {
    var p: Parsed = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(a, "-h") or eql(a, "--help")) {
            p.help = true;
        } else if (eql(a, "--no-tui")) {
            p.no_tui = true;
        } else if (eql(a, "--tui")) {
            p.tui = true;
        } else if (eql(a, "--ascii")) {
            p.opts.ascii = true;
        } else if (eql(a, "--wikilinks")) {
            p.opts.wikilinks = true;
        } else if (eql(a, "--image")) {
            p.image = true;
        } else if (try value(a, "-w", "--width", args, &i)) |v| {
            p.opts.width = std.fmt.parseInt(u16, v, 10) catch return error.BadWidth;
        } else if (try value(a, "-s", "--style", args, &i)) |v| {
            if (!isOneOf(v, &.{ "", "dark", "light", "notty" })) return error.BadStyle;
            p.opts.style = v;
        } else if (try value(a, null, "--graph-dir", args, &i)) |v| {
            if (!std.ascii.eqlIgnoreCase(v, "LR") and !std.ascii.eqlIgnoreCase(v, "TD")) return error.BadGraphDir;
            p.opts.graph_dir = v;
        } else if (try value(a, null, "--image-protocol", args, &i)) |v| {
            if (!isOneOf(v, &.{ "auto", "kitty", "sixel", "halfblocks", "none" })) return error.BadProtocol;
            p.image_protocol = v;
            p.image = true; // picking a protocol implies image mode
        } else if (try value(a, null, "--goto-line", args, &i)) |v| {
            const n = std.fmt.parseInt(usize, v, 10) catch return error.BadLine;
            if (n == 0) return error.BadLine; // source lines are 1-based
            p.opts.goto_line = n;
        } else if (try value(a, null, "--find", args, &i)) |v| {
            p.opts.find = v;
        } else if (eql(a, "-") or a.len <= 1 or a[0] != '-') {
            if (p.path != null) return error.TooManyArgs;
            p.path = a;
        } else {
            return error.UnknownFlag;
        }
    }
    return p;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isOneOf(v: []const u8, set: []const []const u8) bool {
    for (set) |s| if (eql(v, s)) return true;
    return false;
}

/// Returns the value when `a` is `long`, `short`, or `long=value`
/// Returns null when `a` is some other flag
/// Returns error.MissingValue when the flag matches but no value follows.
fn value(
    a: []const u8,
    short: ?[]const u8,
    long: []const u8,
    args: []const [:0]const u8,
    i: *usize,
) Error!?[]const u8 {
    if (eql(a, long) or (short != null and eql(a, short.?))) {
        if (i.* + 1 >= args.len) return error.MissingValue;
        i.* += 1;
        return args[i.*];
    }
    if (a.len > long.len + 1 and std.mem.startsWith(u8, a, long) and a[long.len] == '=') {
        return a[long.len + 1 ..];
    }
    return null;
}

test "parse: file path and separate flag values" {
    const args = [_][:0]const u8{ "--no-tui", "-w", "100", "-s", "dark", "README.md" };
    const p = try parse(&args);
    try std.testing.expect(p.no_tui);
    try std.testing.expectEqual(@as(u16, 100), p.opts.width);
    try std.testing.expectEqualStrings("dark", p.opts.style);
    try std.testing.expectEqualStrings("README.md", p.path.?);
}

test "parse: --width=N and stdin marker" {
    const args = [_][:0]const u8{ "--width=72", "-" };
    const p = try parse(&args);
    try std.testing.expectEqual(@as(u16, 72), p.opts.width);
    try std.testing.expectEqualStrings("-", p.path.?);
}

test "parse: unknown flag errors" {
    const args = [_][:0]const u8{"--nope"};
    try std.testing.expectError(error.UnknownFlag, parse(&args));
}

test "parse: missing value errors" {
    const args = [_][:0]const u8{"--style"};
    try std.testing.expectError(error.MissingValue, parse(&args));
}

test "parse: --image-protocol implies --image" {
    const p = try parse(&[_][:0]const u8{ "--image-protocol", "kitty", "a.md" });
    try std.testing.expect(p.image);
    try std.testing.expectEqualStrings("kitty", p.image_protocol);
}

test "parse: extra positional arguments error instead of being dropped" {
    try std.testing.expectError(error.TooManyArgs, parse(&[_][:0]const u8{ "a.md", "b.md" }));
    try std.testing.expectError(error.TooManyArgs, parse(&[_][:0]const u8{ "a.md", "-" }));
}

test "parse: --goto-line separate and = forms" {
    const p1 = try parse(&[_][:0]const u8{ "--goto-line", "42", "a.md" });
    try std.testing.expectEqual(@as(?usize, 42), p1.opts.goto_line);
    const p2 = try parse(&[_][:0]const u8{"--goto-line=7"});
    try std.testing.expectEqual(@as(?usize, 7), p2.opts.goto_line);
}

test "parse: --goto-line bad values error" {
    try std.testing.expectError(error.BadLine, parse(&[_][:0]const u8{ "--goto-line", "0" }));
    try std.testing.expectError(error.BadLine, parse(&[_][:0]const u8{"--goto-line=abc"}));
    try std.testing.expectError(error.MissingValue, parse(&[_][:0]const u8{"--goto-line"}));
}

test "parse: --find captures text" {
    const p1 = try parse(&[_][:0]const u8{ "--find", "Quick start", "a.md" });
    try std.testing.expectEqualStrings("Quick start", p1.opts.find.?);
    const p2 = try parse(&[_][:0]const u8{"--find=hello"});
    try std.testing.expectEqualStrings("hello", p2.opts.find.?);
    try std.testing.expectError(error.MissingValue, parse(&[_][:0]const u8{"--find"}));
}

test "parse: unknown enum-like values error instead of degrading silently" {
    try std.testing.expectError(error.BadStyle, parse(&[_][:0]const u8{ "-s", "foo" }));
    try std.testing.expectError(error.BadGraphDir, parse(&[_][:0]const u8{"--graph-dir=diagonal"}));
    try std.testing.expectError(error.BadProtocol, parse(&[_][:0]const u8{"--image-protocol=iterm"}));
    const p = try parse(&[_][:0]const u8{"--graph-dir=lr"}); // case-insensitive, like the renderer
    try std.testing.expectEqualStrings("lr", p.opts.graph_dir);
}
