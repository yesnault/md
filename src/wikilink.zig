//! Resolves wikilink targets for the md binary: [[Page]] means the file Page.md
//! sitting next to the document being rendered, and nothing else. No vault-wide
//! search, no aliases, no extension variants.
//!
//! This is the binary's answer to options.WikilinkCheck, which the library
//! leaves open because only a caller knows what resolving means.

const std = @import("std");
const Io = std.Io;
// Via the "md" module, not "options.zig": a relative import would compile a
// second copy of the type into this module, and it would no longer match the
// one render.Options expects.
const options = @import("md").options;

/// Answers "does this target exist" against one directory. `dir` borrows the
/// rendered document's directory, so it has to outlive the render that uses the
/// WikilinkCheck built from it.
pub const Resolver = struct {
    io: Io,
    dir: []const u8,

    pub fn check(self: *Resolver) options.WikilinkCheck {
        return .{ .ctx = self, .exists = exists };
    }
};

/// The resolution rule itself: [[Page]] in `dir` is dir/Page.md.
fn targetPath(buf: []u8, dir: []const u8, target: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}.md", .{ dir, target });
}

fn exists(ctx: ?*anyopaque, target: []const u8) bool {
    const self: *Resolver = @ptrCast(@alignCast(ctx.?));
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = targetPath(&buf, self.dir, target) catch return true;
    Io.Dir.cwd().access(self.io, path, .{}) catch |err| switch (err) {
        // The only error that means the target does not resolve. An unreadable or
        // broken directory says nothing about the target, so leave the link alone.
        error.FileNotFound => return false,
        else => return true,
    };
    return true;
}

test "targetPath resolves a target against the document's directory" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "docs/guide/Page.md",
        try targetPath(&buf, "docs/guide", "Page"),
    );
    // The target is used verbatim (no slugging, no aliasing), and a document
    // with no dirname resolves against ".", like resolveFileTarget does for
    // ordinary links.
    try std.testing.expectEqualStrings(
        "./Page Name.md",
        try targetPath(&buf, ".", "Page Name"),
    );
}

test "exists: a sibling .md resolves, a missing one does not" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "Sibling.md", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Other.txt", .data = "" });

    // Both sides resolve against the cwd, so this holds wherever the test runs.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var r: Resolver = .{ .io = io, .dir = dir };

    // Through the callback, to exercise the ctx round-trip.
    const cb = r.check();
    try std.testing.expect(cb.exists(cb.ctx, "Sibling"));
    try std.testing.expect(!cb.exists(cb.ctx, "Nope"));
    // Other.txt is not Other.md: no extension variants.
    try std.testing.expect(!cb.exists(cb.ctx, "Other"));
}
