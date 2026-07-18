//! Binding to the tree-sitter C runtime and grammar entry points.

pub const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

pub extern fn tree_sitter_json() callconv(.c) *const c.TSLanguage;
pub extern fn tree_sitter_go() callconv(.c) *const c.TSLanguage;
pub extern fn tree_sitter_c() callconv(.c) *const c.TSLanguage;
pub extern fn tree_sitter_python() callconv(.c) *const c.TSLanguage;
pub extern fn tree_sitter_rust() callconv(.c) *const c.TSLanguage;
pub extern fn tree_sitter_javascript() callconv(.c) *const c.TSLanguage;
pub extern fn tree_sitter_bash() callconv(.c) *const c.TSLanguage;
pub extern fn tree_sitter_toml() callconv(.c) *const c.TSLanguage;
pub extern fn tree_sitter_lua() callconv(.c) *const c.TSLanguage;
pub extern fn tree_sitter_zig() callconv(.c) *const c.TSLanguage;
