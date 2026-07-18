//! Syntax highlighting via tree-sitter. Parses a code block, runs the grammar's
//! highlights query, and returns a per-byte Style array (null = use the default
//! code style). The capture→Style mapping uses the theme's CodeHl palette.

const std = @import("std");
const ts = @import("tree_sitter.zig");
const c = ts.c;
const theme = @import("../theme.zig");
const registry = @import("registry.zig");
const Style = theme.Style;

const Cap = struct { start: u32, end: u32, style: Style };

/// A per-byte style array for `code` (length == code.len), or null when the parse
/// or the query fails. Allocated with `arena`, allocation failure propagates.
pub fn highlight(arena: std.mem.Allocator, code: []const u8, lang: registry.Lang, hl: theme.CodeHl) error{OutOfMemory}!?[]?Style {
    const parser = c.ts_parser_new() orelse return null;
    defer c.ts_parser_delete(parser);
    if (!c.ts_parser_set_language(parser, lang.language)) return null;

    const tree = c.ts_parser_parse_string(parser, null, code.ptr, @intCast(code.len)) orelse return null;
    defer c.ts_tree_delete(tree);
    const root = c.ts_tree_root_node(tree);

    var err_off: u32 = undefined;
    var err_type: c.TSQueryError = undefined;
    const query = c.ts_query_new(lang.language, lang.highlights.ptr, @intCast(lang.highlights.len), &err_off, &err_type) orelse return null;
    defer c.ts_query_delete(query);

    const cursor = c.ts_query_cursor_new() orelse return null;
    defer c.ts_query_cursor_delete(cursor);
    c.ts_query_cursor_exec(cursor, query, root);

    var caps: std.ArrayList(Cap) = .empty;
    defer caps.deinit(arena);

    var match: c.TSQueryMatch = undefined;
    while (c.ts_query_cursor_next_match(cursor, &match)) {
        const list = match.captures[0..match.capture_count];
        for (list) |cap| {
            const start = c.ts_node_start_byte(cap.node);
            const end = c.ts_node_end_byte(cap.node);
            if (end <= start) continue;
            var nlen: u32 = 0;
            const name = c.ts_query_capture_name_for_id(query, cap.index, &nlen)[0..nlen];
            const st = captureStyle(hl, name);
            if (st.isPlain()) continue;
            try caps.append(arena, .{ .start = start, .end = end, .style = st });
        }
    }

    // Apply widest captures first so more-specific (shorter) ones win.
    std.mem.sort(Cap, caps.items, {}, cmpWideFirst);
    const styles = try arena.alloc(?Style, code.len);
    @memset(styles, null);
    for (caps.items) |cap| {
        const e = @min(cap.end, @as(u32, @intCast(code.len)));
        var i = cap.start;
        while (i < e) : (i += 1) styles[i] = cap.style;
    }
    return styles;
}

fn cmpWideFirst(_: void, a: Cap, b: Cap) bool {
    return (a.end - a.start) > (b.end - b.start);
}

/// Unknown or non-visual captures come back plain, so the caller keeps the base
/// colour.
fn captureStyle(hl: theme.CodeHl, name: []const u8) Style {
    const sw = std.mem.startsWith;
    if (sw(u8, name, "comment")) return hl.comment;
    if (sw(u8, name, "keyword")) return hl.keyword;
    if (sw(u8, name, "string") or sw(u8, name, "character")) return hl.string;
    if (sw(u8, name, "number") or sw(u8, name, "float") or sw(u8, name, "boolean")) return hl.number;
    if (sw(u8, name, "constant.builtin") or sw(u8, name, "variable.builtin")) return hl.builtin;
    if (sw(u8, name, "constant")) return hl.constant;
    if (sw(u8, name, "type") or sw(u8, name, "constructor")) return hl.type_;
    if (sw(u8, name, "function") or sw(u8, name, "method")) return hl.function;
    if (sw(u8, name, "operator")) return hl.operator;
    if (sw(u8, name, "punctuation")) return hl.punctuation;
    if (sw(u8, name, "property") or sw(u8, name, "field")) return hl.property;
    if (sw(u8, name, "attribute") or sw(u8, name, "tag")) return hl.type_;
    if (sw(u8, name, "label")) return hl.keyword;
    if (sw(u8, name, "variable")) return hl.variable;
    return .{};
}

test "highlight json marks strings and punctuation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lang = registry.lookup("json").?;
    const code = "{\"a\": 1}";
    const styles = (try highlight(arena.allocator(), code, lang, theme.dark.code_hl)) orelse return error.NoStyles;
    try std.testing.expectEqual(code.len, styles.len);
    var any: bool = false;
    for (styles) |s| {
        if (s != null) any = true;
    }
    try std.testing.expect(any); // at least some tokens were highlighted
}
