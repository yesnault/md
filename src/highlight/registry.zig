//! Maps a code fence info string (e.g. "go", "sh") to a tree-sitter grammar and
//! its embedded highlights query. Extending the set is a one-line addition here
//! plus the grammar package in build.zig / build.zig.zon / tools/regen-assets.sh.

const std = @import("std");
const ts = @import("tree_sitter.zig");

pub const Lang = struct {
    language: *const ts.c.TSLanguage,
    highlights: []const u8,
};

const json_hl = @embedFile("queries/json.scm");
const go_hl = @embedFile("queries/go.scm");
const c_hl = @embedFile("queries/c.scm");
const python_hl = @embedFile("queries/python.scm");
const rust_hl = @embedFile("queries/rust.scm");
const javascript_hl = @embedFile("queries/javascript.scm");
const bash_hl = @embedFile("queries/bash.scm");
const toml_hl = @embedFile("queries/toml.scm");
const lua_hl = @embedFile("queries/lua.scm");
const zig_hl = @embedFile("queries/zig.scm");

pub fn lookup(name: []const u8) ?Lang {
    if (eqAny(name, &.{"json"})) return .{ .language = ts.tree_sitter_json(), .highlights = json_hl };
    if (eqAny(name, &.{ "go", "golang" })) return .{ .language = ts.tree_sitter_go(), .highlights = go_hl };
    if (eqAny(name, &.{ "c", "h" })) return .{ .language = ts.tree_sitter_c(), .highlights = c_hl };
    if (eqAny(name, &.{ "python", "py" })) return .{ .language = ts.tree_sitter_python(), .highlights = python_hl };
    if (eqAny(name, &.{ "rust", "rs" })) return .{ .language = ts.tree_sitter_rust(), .highlights = rust_hl };
    if (eqAny(name, &.{ "javascript", "js", "jsx", "node" })) return .{ .language = ts.tree_sitter_javascript(), .highlights = javascript_hl };
    if (eqAny(name, &.{ "bash", "sh", "shell", "zsh", "console" })) return .{ .language = ts.tree_sitter_bash(), .highlights = bash_hl };
    if (eqAny(name, &.{"toml"})) return .{ .language = ts.tree_sitter_toml(), .highlights = toml_hl };
    if (eqAny(name, &.{"lua"})) return .{ .language = ts.tree_sitter_lua(), .highlights = lua_hl };
    if (eqAny(name, &.{"zig"})) return .{ .language = ts.tree_sitter_zig(), .highlights = zig_hl };
    return null;
}

fn eqAny(name: []const u8, set: []const []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}
