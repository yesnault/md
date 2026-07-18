//! Syntax Ref: https://mermaid.ai/open-source/syntax/zenuml.html
//!
//! Mermaid ZenUML: a code-style dialect of the sequence diagram.
//!
//! Parser front-end only. It translates the source into the shared participant +
//! event model and hands off to `sequence.zig`'s `layout`. No renderer lives here.
//! Calls with no explicit caller originate from a `@Starter` participant, created
//! on demand. Multi-line expressions are not supported.

const std = @import("std");
const seq = @import("sequence.zig");
const text = @import("text.zig");

const ws = text.ws;

const frag_kws = [_][]const u8{ "if", "while", "for", "loop", "opt", "par", "alt", "try", "critical", "break" };
const arrow_ops = [_][]const u8{ "->>", "-->", "->" };

const CallFrame = struct { callee: usize, prev_caller: ?usize, ret_label: []const u8 };

pub fn render(arena: std.mem.Allocator, src: []const u8, ascii_mode: bool) ![]const u8 {
    var ps = text.Interner(seq.Participant).init(arena);
    var events: std.ArrayList(seq.Event) = .empty;

    var base_caller: ?usize = null; // @Starter or the lazily-created Starter box
    var calls: std.ArrayList(CallFrame) = .empty;
    defer calls.deinit(arena);
    const Block = enum { frag, call };
    var blocks: std.ArrayList(Block) = .empty;
    defer blocks.deinit(arena);

    var it = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, ws);
        if (first) {
            first = false;
            continue; // skip "zenuml"
        }
        if (t.len == 0 or std.mem.startsWith(u8, t, "%%") or std.mem.startsWith(u8, t, "//")) continue;
        if (std.mem.startsWith(u8, t, "title ") or std.mem.startsWith(u8, t, "title:")) continue;

        // @Starter(X) / @Annotation Name participant declarations.
        if (t[0] == '@') {
            if (std.mem.startsWith(u8, t, "@Starter")) {
                if (extractParen(t)) |id| base_caller = try ps.ensure(id, .{ .display = id });
            } else if (std.mem.indexOfAny(u8, t, " \t")) |sp| {
                const name = std.mem.trim(u8, t[sp + 1 ..], ws);
                if (name.len > 0) _ = try ps.ensure(name, .{ .display = name });
            }
            continue;
        }

        // Block close (and else/catch/finally branch reopen).
        if (t[0] == '}') {
            if (std.mem.endsWith(u8, t, "{")) {
                const label = std.mem.trim(u8, t[1 .. t.len - 1], ws);
                try events.append(arena, .{ .kind = .frag_else, .label = label });
            } else if (blocks.pop()) |b| {
                switch (b) {
                    .frag => try events.append(arena, .{ .kind = .frag_close }),
                    .call => {
                        if (calls.pop()) |cf| {
                            if (cf.prev_caller) |pc| {
                                if (pc != cf.callee)
                                    try events.append(arena, .{ .kind = .msg, .from = cf.callee, .to = pc, .text = cf.ret_label });
                            }
                        }
                    },
                }
            }
            continue;
        }

        const has_body = std.mem.endsWith(u8, t, "{");
        const core = if (has_body) std.mem.trim(u8, t[0 .. t.len - 1], ws) else t;

        // Fragment openers (if/while/...). Keyword alone or followed by a space/paren.
        if (fragKeyword(core)) |_| {
            try events.append(arena, .{ .kind = .frag_open, .label = core });
            try blocks.append(arena, .frag);
            continue;
        }

        if (std.mem.startsWith(u8, core, "return")) {
            // return from the innermost active call to its caller.
            if (calls.items.len > 0) {
                const cf = calls.items[calls.items.len - 1];
                if (cf.prev_caller) |pc| if (pc != cf.callee) {
                    const val = std.mem.trim(u8, core[6..], ws);
                    try events.append(arena, .{ .kind = .msg, .from = cf.callee, .to = pc, .text = val });
                };
            }
            continue;
        }

        // Optional `lhs =` assignment (return-value capture / creation binding).
        var ret_label: []const u8 = "";
        var rhs = core;
        if (findAssign(core)) |eq| {
            ret_label = std.mem.trim(u8, core[0..eq], ws);
            rhs = std.mem.trim(u8, core[eq + 1 ..], ws);
        }

        // Object creation.
        if (std.mem.startsWith(u8, rhs, "new ")) {
            const cls = splitCall(std.mem.trim(u8, rhs[4..], ws)).callee;
            if (cls.len == 0) continue;
            const caller = (try currentCaller(&ps, &calls, &base_caller)) orelse continue;
            const callee = try ps.ensure(cls, .{ .display = cls });
            if (caller != callee) try events.append(arena, .{ .kind = .msg, .from = caller, .to = callee, .text = "new" });
            if (has_body) {
                try calls.append(arena, .{ .callee = callee, .prev_caller = caller, .ret_label = ret_label });
                try blocks.append(arena, .call);
            }
            continue;
        }

        // Resolve caller, callee and message text.
        var caller: ?usize = null;
        var target = rhs;
        if (findArrow(rhs)) |ar| {
            const id = std.mem.trim(u8, rhs[0..ar.idx], ws);
            caller = try ps.ensure(id, .{ .display = id });
            target = std.mem.trim(u8, rhs[ar.idx + ar.len ..], ws);
        }
        var callee_str = target;
        var label: []const u8 = "";
        if (std.mem.indexOfScalar(u8, target, ':')) |c| {
            callee_str = std.mem.trim(u8, target[0..c], ws);
            label = std.mem.trim(u8, target[c + 1 ..], ws);
        } else {
            const sc = splitCall(target);
            callee_str = sc.callee;
            label = sc.text;
        }
        if (callee_str.len == 0) continue;
        const from = caller orelse (try currentCaller(&ps, &calls, &base_caller)) orelse continue;
        const to = try ps.ensure(callee_str, .{ .display = callee_str });
        try events.append(arena, .{ .kind = .msg, .from = from, .to = to, .text = label });

        if (has_body) {
            try calls.append(arena, .{ .callee = to, .prev_caller = from, .ret_label = ret_label });
            try blocks.append(arena, .call);
        } else if (ret_label.len > 0 and from != to) {
            // Captured return value with no body → immediate return arrow.
            try events.append(arena, .{ .kind = .msg, .from = to, .to = from, .text = ret_label });
        }
    }

    var has_msg = false;
    for (events.items) |e| if (e.kind == .msg) {
        has_msg = true;
        break;
    };
    if (!has_msg) return error.Empty;
    return seq.layout(arena, ps.items.items, events.items, ascii_mode);
}

/// The callee of the innermost active call, or the Starter participant for
/// top-level statements, created lazily.
fn currentCaller(ps: *text.Interner(seq.Participant), calls: *std.ArrayList(CallFrame), base: *?usize) !?usize {
    if (calls.items.len > 0) return calls.items[calls.items.len - 1].callee;
    if (base.*) |b| return b;
    const i = try ps.ensure("Starter", .{ .display = "Starter" });
    base.* = i;
    return i;
}

const Split = struct { callee: []const u8, text: []const u8 };

/// `B.method(args)` into callee `B` and text `method(args)`. With no dot it is all
/// callee, args stripped, and the text comes back empty.
fn splitCall(s: []const u8) Split {
    const paren = std.mem.indexOfScalar(u8, s, '(') orelse s.len;
    if (std.mem.indexOfScalar(u8, s[0..paren], '.')) |dot| {
        return .{ .callee = std.mem.trim(u8, s[0..dot], ws), .text = std.mem.trim(u8, s[dot + 1 ..], ws) };
    }
    return .{ .callee = std.mem.trim(u8, s[0..paren], ws), .text = "" };
}

const Arrow = struct { idx: usize, len: usize };

fn findArrow(s: []const u8) ?Arrow {
    for (arrow_ops) |op| {
        if (std.mem.indexOf(u8, s, op)) |i| return .{ .idx = i, .len = op.len };
    }
    return null;
}

/// A fragment opener: the keyword alone, or followed by a space or `(`.
fn fragKeyword(core: []const u8) ?[]const u8 {
    for (frag_kws) |k| {
        if (std.mem.eql(u8, core, k)) return k;
        if (std.mem.startsWith(u8, core, k) and core.len > k.len and (core[k.len] == ' ' or core[k.len] == '\t' or core[k.len] == '(')) return k;
    }
    return null;
}

/// Index of a plain `=` assignment occurring before any `(`, skipping
/// `==`/`<=`/`>=`/`!=`.
fn findAssign(s: []const u8) ?usize {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '(') return null;
        if (s[i] == '=') {
            const prev: u8 = if (i > 0) s[i - 1] else ' ';
            const next: u8 = if (i + 1 < s.len) s[i + 1] else ' ';
            if (prev != '<' and prev != '>' and prev != '!' and prev != '=' and next != '=') return i;
        }
    }
    return null;
}

fn extractParen(s: []const u8) ?[]const u8 {
    const o = std.mem.indexOfScalar(u8, s, '(') orelse return null;
    const c = std.mem.indexOfScalarPos(u8, s, o, ')') orelse return null;
    return std.mem.trim(u8, s[o + 1 .. c], ws);
}

test "zenuml renders plain messages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "zenuml\n" ++
        "title Greeting\n" ++
        "@Actor Alice\n" ++
        "@Database Bob\n" ++
        "Alice->Bob: Hello\n" ++
        "Bob->Alice: Hi\n";
    const art = try render(arena.allocator(), src, false);
    for ([_][]const u8{ "Alice", "Bob", "Hello", "Hi" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, art, needle) != null);
    }
}

test "zenuml method calls, return value and fragment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "zenuml\n" ++
        "@Starter(Client)\n" ++
        "Order.create() {\n" ++
        "  ret = Database.save()\n" ++
        "}\n" ++
        "if (ok) {\n" ++
        "  Order->Client: confirmed\n" ++
        "}\n";
    const art = try render(arena.allocator(), src, true);
    for ([_][]const u8{ "Client", "Order", "Database", "create()", "save()", "ret", "confirmed" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, art, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, art, "(ok)") != null); // fragment frame label (spaces become line glyphs)
}

test "zenuml self-call renders as a self-loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "zenuml\n" ++
        "A->B: start\n" ++
        "B->B: tick\n";
    const art = try render(arena.allocator(), src, false);
    try std.testing.expect(std.mem.indexOf(u8, art, "tick") != null);
}

test "zenuml object creation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "zenuml\n" ++
        "@Starter(A)\n" ++
        "p = new Payment()\n" ++
        "A->Payment: charge\n";
    const art = try render(arena.allocator(), src, true);
    try std.testing.expect(std.mem.indexOf(u8, art, "Payment") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "new") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "charge") != null);
}

test "findArrow tries ->> before -> so the longer op wins" {
    try std.testing.expectEqual(Arrow{ .idx = 5, .len = 2 }, findArrow("Alice->Bob").?);
    // Priority order matters: ->> must not be read as -> (len 3, not 2).
    try std.testing.expectEqual(Arrow{ .idx = 1, .len = 3 }, findArrow("A->>B").?);
    try std.testing.expectEqual(Arrow{ .idx = 1, .len = 3 }, findArrow("A-->B").?);
    try std.testing.expectEqual(@as(?Arrow, null), findArrow("Alice Bob"));
}

test "findAssign detects assignment, skipping comparisons and args" {
    try std.testing.expectEqual(@as(?usize, 2), findAssign("x = y"));
    // Comparison operators are not assignments.
    try std.testing.expectEqual(@as(?usize, null), findAssign("a == b"));
    try std.testing.expectEqual(@as(?usize, null), findAssign("a <= b"));
    try std.testing.expectEqual(@as(?usize, null), findAssign("a >= b"));
    try std.testing.expectEqual(@as(?usize, null), findAssign("a != b"));
    // An = inside call args (after a '(') is ignored...
    try std.testing.expectEqual(@as(?usize, null), findAssign("f(a = b)"));
    // ...but an outer assignment is found before reaching the '('.
    try std.testing.expectEqual(@as(?usize, 2), findAssign("r = f(a=b)"));
    try std.testing.expectEqual(@as(?usize, null), findAssign("plain"));
}

test "zenuml splitCall separates callee from method text on the first dot" {
    const a = splitCall("B.method(args)");
    try std.testing.expectEqualStrings("B", a.callee);
    try std.testing.expectEqualStrings("method(args)", a.text);
    const b = splitCall("Database");
    try std.testing.expectEqualStrings("Database", b.callee);
    try std.testing.expectEqualStrings("", b.text);
    const c = splitCall("foo()"); // no dot: all callee, args stripped, empty text
    try std.testing.expectEqualStrings("foo", c.callee);
    try std.testing.expectEqualStrings("", c.text);
}

test "zenuml extractParen returns the trimmed contents of the first (...)" {
    try std.testing.expectEqualStrings("Client", extractParen("@Starter(Client)").?);
    try std.testing.expectEqualStrings("A", extractParen("@Starter( A )").?);
    try std.testing.expectEqual(@as(?[]const u8, null), extractParen("noparens"));
    try std.testing.expectEqual(@as(?[]const u8, null), extractParen("open("));
}
