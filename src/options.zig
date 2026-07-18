//! Rendering options and terminal width detection.

const std = @import("std");
const builtin = @import("builtin");
const theme = @import("theme.zig");

pub const default_width: u16 = 80;
/// Caps the word-wrap width so text stays readable on very wide terminals.
pub const max_width: u16 = 120;

pub const Protocol = enum {
    auto,
    kitty,
    sixel,
    halfblocks,
    none,

    pub fn parse(s: []const u8) Protocol {
        if (std.mem.eql(u8, s, "auto")) return .auto;
        if (std.mem.eql(u8, s, "kitty")) return .kitty;
        if (std.mem.eql(u8, s, "sixel")) return .sixel;
        if (std.mem.eql(u8, s, "halfblocks")) return .halfblocks;
        return .none;
    }
};

/// How the renderer asks the caller whether a wikilink target resolves, so it can
/// mark [[missing]] as broken. Only the caller knows what resolving means, so it
/// supplies `exists` and the renderer calls it. `ctx` is the caller's state,
/// handed back untouched on every call, null when the check needs none.
///
/// See src/wikilink.zig for the md binary's own implementation.
pub const WikilinkCheck = struct {
    ctx: ?*anyopaque = null,
    exists: *const fn (ctx: ?*anyopaque, target: []const u8) bool,
};

/// Width 0 means "detect from the terminal". An empty style selects automatically.
pub const Options = struct {
    width: u16 = 0,
    style: []const u8 = "",
    /// When set, wins over `style` (for callers that build their own Theme).
    theme: ?theme.Theme = null,
    ascii: bool = false,
    /// "", "LR" or "TD".
    graph_dir: []const u8 = "",
    image: bool = false,
    protocol: Protocol = .auto,
    /// Turn [[target]] / [[target|label]] into links. Off, they stay literal text.
    wikilinks: bool = false,
    /// Marks unresolvable wikilink targets (styled as wikilink_broken).
    wikilink_check: ?WikilinkCheck = null,
    /// TUI only: 1-based source line. On startup, scroll to the heading of the
    /// section that contains it.
    goto_line: ?usize = null,
    /// TUI only: on startup, scroll to the first rendered line containing this
    /// text (ASCII case-insensitive), at or after the --goto-line target.
    find: ?[]const u8 = null,
};

/// Capped at max_width, and default_width when the size cannot be determined.
pub fn detectWidth() u16 {
    const cols = terminalCols() orelse return default_width;
    if (cols == 0) return default_width;
    return @min(cols, max_width);
}

fn terminalCols() ?u16 {
    if (builtin.os.tag == .windows) return null;
    var ws: std.posix.winsize = undefined;
    const rc = std.c.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, &ws);
    if (rc != 0) return null;
    return ws.col;
}

test "Protocol.parse maps names and falls back to none" {
    try std.testing.expectEqual(Protocol.kitty, Protocol.parse("kitty"));
    try std.testing.expectEqual(Protocol.auto, Protocol.parse("auto"));
    try std.testing.expectEqual(Protocol.none, Protocol.parse("bogus"));
}
