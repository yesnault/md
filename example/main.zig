//! Example: use `md` as a library — render a Markdown string to styled ANSI
//! and print it to stdout.

const std = @import("std");
const Io = std.Io;
const md = @import("md");

const document =
    \\# md as a library
    \\
    \\**md** renders Markdown to styled ANSI you can print to any terminal.
    \\
    \\- Headings, lists and tables
    \\- `inline code` and fenced code blocks
    \\- [links](https://github.com/yesnault/md)
    \\
    \\```zig
    \\const md = @import("md");
    \\const ansi = try md.renderToAnsi(gpa, source, .{});
    \\```
    \\
    \\> Rendered by md, called as a library.
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    const ansi = try md.renderToAnsi(gpa, document, .{ .width = 72, .style = "dark" });

    var buf: [4096]u8 = undefined;
    var writer: Io.File.Writer = .init(.stdout(), io, &buf);
    try writer.interface.writeAll(ansi);
    try writer.interface.flush();
}
