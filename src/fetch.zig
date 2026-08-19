//! Fetches a Markdown document over HTTP(S).
//!
//! Only the binary uses this: the "md" library stays free of network code.

const std = @import("std");
const Io = std.Io;

/// Caps a server that never stops sending. No hand-written document comes close.
const max_body = 32 * 1024 * 1024;

/// Nothing in std bounds a request. A server that stalls mid-body, or an
/// unroutable address reached through a redirect, would hang md for good.
///
/// In the TUI that freeze is total. The fetch runs inside the key handler, and
/// the event loop never gets to read Ctrl-C.
const timeout_seconds = 30;

pub fn isUrl(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "http://") or std.mem.startsWith(u8, s, "https://");
}

/// url is the location the body finally came from: redirects make it differ
/// from the requested one, and relative links resolve against it.
pub const Doc = struct { body: []u8, url: []u8 };

/// A server that answers with something we refuse to render has still answered.
/// These two cases carry what the error message needs to name. Transport
/// failures stay in the error set.
pub const Result = union(enum) {
    /// Owned by the caller's allocator.
    ok: Doc,
    /// The content-type as received, "" when the server sent none. Owned by the
    /// caller's allocator unless it is that empty literal.
    not_markdown: []const u8,
    bad_status: std.http.Status,
    /// The http URL a redirect landed on. Owned by the caller's allocator.
    insecure_redirect: []const u8,

    fn free(r: Result, alloc: std.mem.Allocator) void {
        switch (r) {
            .ok => |d| {
                alloc.free(d.body);
                alloc.free(d.url);
            },
            .not_markdown, .insecure_redirect => |s| alloc.free(s),
            .bad_status => {},
        }
    }
};

/// Follows redirects, and gives up after timeout_seconds. Everything returned
/// is owned by alloc.
///
/// anyerror because Select needs a nameable field type and nobody has spelled
/// out the composed set yet. Worth tightening.
pub fn get(io: Io, alloc: std.mem.Allocator, url: []const u8) anyerror!Result {
    const Outcome = union(enum) { fetched: anyerror!Result, expired: void };
    // Room for both tasks, otherwise cancel deadlocks.
    var slots: [2]Outcome = undefined;
    var sel: Io.Select(Outcome) = .init(io, &slots);
    // Only ever one thread in alloc at a time: this one blocks in await until
    // the fetch is done, and cancel below waits for it before returning.
    sel.async(.fetched, doGet, .{ io, alloc, url });
    sel.async(.expired, expire, .{io});

    switch (try sel.await()) {
        .fetched => |res| {
            sel.cancelDiscard(); // the timer holds nothing
            return res;
        },
        .expired => {
            // doGet can still have finished in the gap between the timer firing
            // and this line, holding a body it allocated. Drain, don't discard.
            while (sel.cancel()) |o| switch (o) {
                .fetched => |res| if (res) |r| r.free(alloc) else |_| {},
                .expired => {},
            };
            return error.Timeout;
        },
    }
}

fn expire(io: Io) void {
    // .awake, not .boot: a laptop suspended mid-fetch should not wake up to a
    // request that already timed out.
    io.sleep(.fromSeconds(timeout_seconds), .awake) catch {};
}

fn doGet(io: Io, alloc: std.mem.Allocator, url: []const u8) anyerror!Result {
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();
    try req.sendBodiless();

    // req.uri aliases this buffer after a redirect: it has to outlive the
    // allocPrint below.
    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    // std follows a redirect into any scheme it supports: whoever answers an
    // https URL can walk it down to cleartext. Nothing legitimate does that.
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https") and !std.ascii.eqlIgnoreCase(req.uri.scheme, "https"))
        return .{ .insecure_redirect = try std.fmt.allocPrint(alloc, "{f}", .{&req.uri}) };

    if (response.head.status.class() != .success) return .{ .bad_status = response.head.status };

    // Response.reader() invalidates the head strings, and req.deinit() hands the
    // connection back: copy what we still need out first.
    const content_type = if (response.head.content_type) |ct| try alloc.dupe(u8, ct) else null;
    errdefer if (content_type) |ct| alloc.free(ct);
    const final_url = try std.fmt.allocPrint(alloc, "{f}", .{&req.uri});
    errdefer alloc.free(final_url);

    // The client advertises gzip and deflate by default.
    const decompress_buf: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try alloc.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try alloc.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer alloc.free(decompress_buf);

    var transfer_buf: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buf);
    const body = reader.allocRemaining(alloc, .limited(max_body)) catch |err| switch (err) {
        // bodyErr is null when the read died below the body framing, which is
        // what a cancelation on timeout looks like from here.
        error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        else => |e| return e,
    };
    errdefer alloc.free(body);

    if (!isMarkdown(content_type, body)) {
        alloc.free(body);
        alloc.free(final_url);
        return .{ .not_markdown = content_type orelse "" };
    }
    if (content_type) |ct| alloc.free(ct);
    return .{ .ok = .{ .body = body, .url = final_url } };
}

/// content_type is the raw header value, null when the server sent none.
///
/// The bytes get inspected whatever the header claims: a mislabelled binary
/// would write control sequences straight into the terminal.
fn isMarkdown(content_type: ?[]const u8, body: []const u8) bool {
    if (!isText(body)) return false;
    const raw = content_type orelse return !isHtmlish(body);
    var buf: [64]u8 = undefined;
    const t = mediaType(raw, &buf);
    if (t.len == 0) return !isHtmlish(body);
    if (eql(t, "text/markdown") or eql(t, "text/x-markdown")) return true;
    // Plenty of servers hand out .md as plain text or as an opaque download.
    if (eql(t, "text/plain") or eql(t, "application/octet-stream")) return !isHtmlish(body);
    return false;
}

/// The content-type without its parameters, lowercased. A value too long for
/// buf comes back as-is and matches nothing.
fn mediaType(raw: []const u8, buf: []u8) []const u8 {
    const semi = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
    const t = std.mem.trim(u8, raw[0..semi], " \t");
    if (t.len > buf.len) return t;
    return std.ascii.lowerString(buf[0..t.len], t);
}

fn isText(body: []const u8) bool {
    if (std.mem.indexOfScalar(u8, body, 0) != null) return false;
    return std.unicode.utf8ValidateSlice(body);
}

fn isHtmlish(body: []const u8) bool {
    const s = std.mem.trimStart(u8, body, " \t\r\n");
    return std.ascii.startsWithIgnoreCase(s, "<!doctype") or
        std.ascii.startsWithIgnoreCase(s, "<html");
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// One request, served from a loopback socket. No network involved.
///
/// net.Server exposes no way to read back an ephemeral port. A free one gets
/// hunted over a range instead: CI runs share a machine.
const TestServer = struct {
    server: std.Io.net.Server,
    port: u16,
    reply: []const u8,

    fn start(io: Io, reply: []const u8) !TestServer {
        var port: u16 = 40100;
        while (port < 40160) : (port += 1) {
            const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
            const s = addr.listen(io, .{}) catch continue;
            return .{ .server = s, .port = port, .reply = reply };
        }
        return error.NoFreePort;
    }

    /// Reads the request head and writes reply verbatim. A test can shape any
    /// response it likes, well-formed or not.
    fn serveOne(ts: *TestServer, io: Io) void {
        var stream = ts.server.accept(io) catch return;
        defer stream.close(io);
        var in_buf: [4096]u8 = undefined;
        var out_buf: [4096]u8 = undefined;
        var r = stream.reader(io, &in_buf);
        var w = stream.writer(io, &out_buf);
        // Drain the request head, up to its blank line. The tests send no body.
        while (r.interface.takeDelimiterInclusive('\n')) |line| {
            if (line.len <= 2) break; // "\r\n"
        } else |_| {}
        w.interface.writeAll(ts.reply) catch {};
        w.interface.flush() catch {};
    }

    fn deinit(ts: *TestServer, io: Io) void {
        ts.server.deinit(io);
    }
};

fn getFromTestServer(gpa: std.mem.Allocator, reply: []const u8) !Result {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ts = try TestServer.start(io, reply);
    defer ts.deinit(io);
    // Built here, not in start: the URL has to outlive the frame that made it.
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/doc.md", .{ts.port});

    var group: Io.Group = .init;
    defer group.cancel(io);
    group.async(io, TestServer.serveOne, .{ &ts, io });

    return get(io, gpa, url);
}

test "get on a 404 reports the status" {
    const gpa = std.testing.allocator;
    const res = try getFromTestServer(gpa, "HTTP/1.1 404 Not Found\r\nContent-Type: text/markdown\r\nContent-Length: 5\r\n\r\n# hi\n");
    defer res.free(gpa);
    try std.testing.expectEqual(std.http.Status.not_found, res.bad_status);
}

test "get on text/html reports the type" {
    const gpa = std.testing.allocator;
    const res = try getFromTestServer(gpa, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 25\r\n\r\n<!doctype html><h1>x</h1>");
    defer res.free(gpa);
    try std.testing.expectEqualStrings("text/html", res.not_markdown);
}

test "get returns the body and the final URL" {
    const gpa = std.testing.allocator;
    const res = try getFromTestServer(gpa, "HTTP/1.1 200 OK\r\nContent-Type: text/markdown\r\nContent-Length: 5\r\n\r\n# hi\n");
    defer res.free(gpa);
    try std.testing.expectEqualStrings("# hi\n", res.ok.body);
    try std.testing.expect(std.mem.endsWith(u8, res.ok.url, "/doc.md"));
}

test "get sniffs an octet-stream body" {
    // What python's http.server does with .md.
    const gpa = std.testing.allocator;
    const res = try getFromTestServer(gpa, "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 5\r\n\r\n# hi\n");
    defer res.free(gpa);
    try std.testing.expectEqualStrings("# hi\n", res.ok.body);
}

test "isUrl accepts only http and https" {
    try std.testing.expect(isUrl("http://host/foo.md"));
    try std.testing.expect(isUrl("https://host/foo.md"));
    try std.testing.expect(!isUrl("foo.md"));
    try std.testing.expect(!isUrl("/tmp/foo.md"));
    try std.testing.expect(!isUrl("ftp://host/foo.md"));
    try std.testing.expect(!isUrl("-"));
}

test "isMarkdown accepts declared Markdown, with or without parameters" {
    try std.testing.expect(isMarkdown("text/markdown", "# hi\n"));
    try std.testing.expect(isMarkdown("text/markdown; charset=utf-8", "# hi\n"));
    try std.testing.expect(isMarkdown("text/x-markdown", "# hi\n"));
    try std.testing.expect(isMarkdown("TEXT/Markdown", "# hi\n"));
}

test "isMarkdown accepts plain text and opaque downloads that read as text" {
    try std.testing.expect(isMarkdown("text/plain", "# hi\n"));
    try std.testing.expect(isMarkdown("  TEXT/PLAIN ; charset=UTF-8", "# hi\n"));
    try std.testing.expect(isMarkdown("application/octet-stream", "# hi\n"));
    try std.testing.expect(isMarkdown(null, "# hi\n"));
    try std.testing.expect(isMarkdown(null, ""));
}

test "isMarkdown rejects html, json and png types" {
    try std.testing.expect(!isMarkdown("text/html", "# hi\n"));
    try std.testing.expect(!isMarkdown("application/json", "# hi\n"));
    try std.testing.expect(!isMarkdown("image/png", "# hi\n"));
}

test "isMarkdown rejects HTML served under a permissive type" {
    // The common case: a server hands out an error page as text/plain.
    try std.testing.expect(!isMarkdown("text/plain", "<!DOCTYPE html>\n<title>404</title>"));
    try std.testing.expect(!isMarkdown(null, "  \n<html><body>nope</body></html>"));
    try std.testing.expect(!isMarkdown("application/octet-stream", "<HTML>"));
}

test "isMarkdown rejects binary and invalid UTF-8" {
    try std.testing.expect(!isMarkdown("text/markdown", "PK\x03\x04\x00\x00binary"));
    try std.testing.expect(!isMarkdown("text/plain", "text\x00more"));
    try std.testing.expect(!isMarkdown("text/markdown", "\xff\xfe not utf-8"));
}
