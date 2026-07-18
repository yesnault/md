//! Color themes and ANSI SGR emission.
//!
//! A small, extensible set of style profiles (dark, light, notty). Each element
//! maps to a Style. The renderer resolves a Style per word and emits a
//! self-contained SGR sequence followed by a reset.

const std = @import("std");

pub const Color = union(enum) {
    none,
    ansi256: u8,
    rgb: [3]u8,
};

fn colorIsNone(c: Color) bool {
    return c == .none;
}

fn colorEql(a: Color, b: Color) bool {
    return std.meta.eql(a, b);
}

pub const Style = struct {
    fg: Color = .none,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strike: bool = false,
    faint: bool = false,

    pub fn isPlain(self: Style) bool {
        return colorIsNone(self.fg) and !self.bold and !self.italic and
            !self.underline and !self.strike and !self.faint;
    }

    pub fn eql(a: Style, b: Style) bool {
        return colorEql(a.fg, b.fg) and a.bold == b.bold and a.italic == b.italic and
            a.underline == b.underline and a.strike == b.strike and a.faint == b.faint;
    }

    /// Layers `over` on top of `base`: attributes OR together, and a foreground set
    /// in `over` wins.
    pub fn merge(base: Style, over: Style) Style {
        return .{
            .fg = if (colorIsNone(over.fg)) base.fg else over.fg,
            .bold = base.bold or over.bold,
            .italic = base.italic or over.italic,
            .underline = base.underline or over.underline,
            .strike = base.strike or over.strike,
            .faint = base.faint or over.faint,
        };
    }
};

pub fn appendOpen(list: *std.ArrayList(u8), alloc: std.mem.Allocator, s: Style) !void {
    if (s.isPlain()) return;
    try list.appendSlice(alloc, "\x1b[");
    var need_semi = false;
    if (s.bold) try emitCode(list, alloc, &need_semi, "1");
    if (s.faint) try emitCode(list, alloc, &need_semi, "2");
    if (s.italic) try emitCode(list, alloc, &need_semi, "3");
    if (s.underline) try emitCode(list, alloc, &need_semi, "4");
    if (s.strike) try emitCode(list, alloc, &need_semi, "9");
    switch (s.fg) {
        .none => {},
        .ansi256 => |n| {
            var buf: [16]u8 = undefined;
            try emitCode(list, alloc, &need_semi, try std.fmt.bufPrint(&buf, "38;5;{d}", .{n}));
        },
        .rgb => |rgb| {
            var buf: [24]u8 = undefined;
            try emitCode(list, alloc, &need_semi, try std.fmt.bufPrint(&buf, "38;2;{d};{d};{d}", .{ rgb[0], rgb[1], rgb[2] }));
        },
    }
    try list.append(alloc, 'm');
}

fn emitCode(list: *std.ArrayList(u8), alloc: std.mem.Allocator, need_semi: *bool, code: []const u8) !void {
    if (need_semi.*) try list.append(alloc, ';');
    try list.appendSlice(alloc, code);
    need_semi.* = true;
}

pub fn appendReset(list: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    try list.appendSlice(alloc, "\x1b[0m");
}

pub const CodeHl = struct {
    keyword: Style = .{},
    type_: Style = .{},
    function: Style = .{},
    string: Style = .{},
    number: Style = .{},
    comment: Style = .{},
    constant: Style = .{},
    operator: Style = .{},
    punctuation: Style = .{},
    variable: Style = .{},
    property: Style = .{},
    builtin: Style = .{},
};

pub const Theme = struct {
    text: Style = .{},
    /// Styles per heading level, indexed by level - 1: [0] = H1 ... [5] = H6.
    heading: [6]Style = @splat(.{}),
    emph: Style = .{},
    strong: Style = .{},
    code_span: Style = .{},
    code_block: Style = .{},
    link: Style = .{},
    link_text: Style = .{},
    wikilink: Style = .{},
    wikilink_broken: Style = .{},
    image: Style = .{},
    quote: Style = .{},
    quote_bar: Style = .{},
    list_marker: Style = .{},
    rule: Style = .{},
    del: Style = .{},
    table_header: Style = .{},
    table_border: Style = .{},
    code_hl: CodeHl = .{},
};

/// "", "auto" and unknown names all fall back to dark.
pub fn byName(name: []const u8) Theme {
    if (std.mem.eql(u8, name, "notty")) return notty;
    if (std.mem.eql(u8, name, "light")) return light;
    return dark;
}

pub const dark: Theme = .{
    .text = .{},
    .heading = .{
        .{ .bold = true, .underline = true, .fg = .{ .ansi256 = 39 } },
        .{ .bold = true, .fg = .{ .ansi256 = 39 } },
        .{ .bold = true, .fg = .{ .ansi256 = 75 } },
        .{ .bold = true, .fg = .{ .ansi256 = 111 } },
        .{ .bold = true, .fg = .{ .ansi256 = 146 } },
        .{ .bold = true, .faint = true },
    },
    .emph = .{ .italic = true },
    .strong = .{ .bold = true },
    .code_span = .{ .fg = .{ .ansi256 = 204 } },
    .code_block = .{ .fg = .{ .ansi256 = 252 } },
    .link = .{ .fg = .{ .ansi256 = 39 }, .underline = true },
    .link_text = .{ .fg = .{ .ansi256 = 39 } },
    .wikilink = .{ .fg = .{ .ansi256 = 79 }, .underline = true },
    .wikilink_broken = .{ .fg = .{ .ansi256 = 203 }, .strike = true },
    .image = .{ .fg = .{ .ansi256 = 141 } },
    .quote = .{ .italic = true, .faint = true },
    .quote_bar = .{ .fg = .{ .ansi256 = 240 } },
    .list_marker = .{ .fg = .{ .ansi256 = 39 } },
    .rule = .{ .faint = true },
    .del = .{ .strike = true },
    .table_header = .{ .bold = true },
    .table_border = .{ .faint = true },
    .code_hl = .{
        .keyword = .{ .fg = .{ .ansi256 = 176 } },
        .type_ = .{ .fg = .{ .ansi256 = 80 } },
        .function = .{ .fg = .{ .ansi256 = 39 } },
        .string = .{ .fg = .{ .ansi256 = 114 } },
        .number = .{ .fg = .{ .ansi256 = 215 } },
        .comment = .{ .fg = .{ .ansi256 = 244 }, .italic = true, .faint = true },
        .constant = .{ .fg = .{ .ansi256 = 215 } },
        .operator = .{ .fg = .{ .ansi256 = 252 } },
        .punctuation = .{ .fg = .{ .ansi256 = 245 } },
        .variable = .{},
        .property = .{ .fg = .{ .ansi256 = 117 } },
        .builtin = .{ .fg = .{ .ansi256 = 215 } },
    },
};

pub const light: Theme = .{
    .text = .{},
    .heading = .{
        .{ .bold = true, .underline = true, .fg = .{ .ansi256 = 25 } },
        .{ .bold = true, .fg = .{ .ansi256 = 25 } },
        .{ .bold = true, .fg = .{ .ansi256 = 26 } },
        .{ .bold = true, .fg = .{ .ansi256 = 60 } },
        .{ .bold = true, .fg = .{ .ansi256 = 66 } },
        .{ .bold = true, .faint = true },
    },
    .emph = .{ .italic = true },
    .strong = .{ .bold = true },
    .code_span = .{ .fg = .{ .ansi256 = 88 } },
    .code_block = .{ .fg = .{ .ansi256 = 238 } },
    .link = .{ .fg = .{ .ansi256 = 26 }, .underline = true },
    .link_text = .{ .fg = .{ .ansi256 = 26 } },
    .wikilink = .{ .fg = .{ .ansi256 = 29 }, .underline = true },
    .wikilink_broken = .{ .fg = .{ .ansi256 = 124 }, .strike = true },
    .image = .{ .fg = .{ .ansi256 = 91 } },
    .quote = .{ .italic = true, .faint = true },
    .quote_bar = .{ .fg = .{ .ansi256 = 246 } },
    .list_marker = .{ .fg = .{ .ansi256 = 26 } },
    .rule = .{ .faint = true },
    .del = .{ .strike = true },
    .table_header = .{ .bold = true },
    .table_border = .{ .faint = true },
    .code_hl = .{
        .keyword = .{ .fg = .{ .ansi256 = 92 } },
        .type_ = .{ .fg = .{ .ansi256 = 24 } },
        .function = .{ .fg = .{ .ansi256 = 26 } },
        .string = .{ .fg = .{ .ansi256 = 28 } },
        .number = .{ .fg = .{ .ansi256 = 130 } },
        .comment = .{ .fg = .{ .ansi256 = 245 }, .italic = true },
        .constant = .{ .fg = .{ .ansi256 = 130 } },
        .operator = .{ .fg = .{ .ansi256 = 238 } },
        .punctuation = .{ .fg = .{ .ansi256 = 242 } },
        .variable = .{},
        .property = .{ .fg = .{ .ansi256 = 31 } },
        .builtin = .{ .fg = .{ .ansi256 = 130 } },
    },
};

/// Plain text: every field keeps its unstyled default.
pub const notty: Theme = .{};

test "colorEql compares the tag and the whole payload" {
    // Every rgb component counts.
    try std.testing.expect(colorEql(.{ .rgb = .{ 1, 2, 3 } }, .{ .rgb = .{ 1, 2, 3 } }));
    try std.testing.expect(!colorEql(.{ .rgb = .{ 9, 2, 3 } }, .{ .rgb = .{ 1, 2, 3 } }));
    try std.testing.expect(!colorEql(.{ .rgb = .{ 1, 9, 3 } }, .{ .rgb = .{ 1, 2, 3 } }));
    try std.testing.expect(!colorEql(.{ .rgb = .{ 1, 2, 9 } }, .{ .rgb = .{ 1, 2, 3 } }));

    try std.testing.expect(colorEql(.{ .ansi256 = 39 }, .{ .ansi256 = 39 }));
    try std.testing.expect(!colorEql(.{ .ansi256 = 39 }, .{ .ansi256 = 40 }));
    try std.testing.expect(colorEql(.none, .none));

    // Same bytes, different variant: a payload-only compare would collapse distinct
    // SGR sequences into one run.
    try std.testing.expect(!colorEql(.none, .{ .ansi256 = 0 }));
    try std.testing.expect(!colorEql(.{ .ansi256 = 0 }, .{ .rgb = .{ 0, 0, 0 } }));
}

test "a none foreground means unset, not black" {
    try std.testing.expect((Style{}).isPlain());
    try std.testing.expect(!(Style{ .fg = .{ .ansi256 = 0 } }).isPlain());
    try std.testing.expect(!(Style{ .bold = true }).isPlain());

    // merge: `over` only overrides the foreground when it actually sets one.
    const base: Style = .{ .fg = .{ .ansi256 = 39 } };
    try std.testing.expect(colorEql(base.merge(.{ .bold = true }).fg, .{ .ansi256 = 39 }));
    try std.testing.expect(colorEql(base.merge(.{ .fg = .{ .rgb = .{ 1, 2, 3 } } }).fg, .{ .rgb = .{ 1, 2, 3 } }));
}

test "appendOpen emits SGR and isPlain skips it" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try appendOpen(&list, gpa, .{ .bold = true, .fg = .{ .ansi256 = 39 } });
    try std.testing.expectEqualStrings("\x1b[1;38;5;39m", list.items);

    list.clearRetainingCapacity();
    try appendOpen(&list, gpa, .{});
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}
