//! Syntax Ref: https://mermaid.ai/open-source/syntax/c4.html
//!
//! Mermaid C4: Context / Container / Component / Dynamic / Deployment.
//!
//! C4's function-call syntax maps onto the flowchart engine, the same trick as the
//! class/ER renderer: elements become boxes (the call keyword turns into a
//! `<<stereotype>>` compartment), relationships become edges, boundaries become
//! nested clusters. All five variants share the parser. C4Dynamic numbers its
//! relationships in source order.

const std = @import("std");
const fc = @import("flowchart.zig");
const text = @import("text.zig");

const ws = text.ws;

pub fn render(arena: std.mem.Allocator, src: []const u8, ascii: bool) ![]const u8 {
    var st = text.Interner(fc.Node).init(arena);
    var edges: std.ArrayList(fc.Edge) = .empty;
    var bodies: std.StringHashMap(std.ArrayList([]const u8)) = .init(arena);

    var clusters: std.ArrayList(fc.Cluster) = .empty;
    var cluster_stack: std.ArrayList(usize) = .empty;
    var node_cluster: std.StringHashMap(usize) = .init(arena);

    var title: []const u8 = "";
    var dynamic = false;
    var rel_no: usize = 0;

    var it = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, ws);
        if (first) {
            first = false;
            dynamic = eqIgnoreCase(firstWord(t), "c4dynamic");
            continue;
        }
        if (t.len == 0 or std.mem.startsWith(u8, t, "%%")) continue;
        if (std.mem.startsWith(u8, t, "title ")) {
            title = std.mem.trim(u8, t[6..], ws);
            continue;
        }
        if (std.mem.eql(u8, t, "}")) {
            if (cluster_stack.items.len > 0) _ = cluster_stack.pop();
            continue;
        }
        // Styling/layout directives have no text-art equivalent.
        if (std.mem.startsWith(u8, t, "Update")) continue;

        // Boundary / deployment-node opener: the line ends with '{'.
        if (std.mem.endsWith(u8, t, "{")) {
            const head = std.mem.trim(u8, t[0 .. t.len - 1], ws);
            const call = splitCall(head) orelse continue;
            const args = try parseArgs(arena, call.inner);
            const ttl = if (args.len > 1 and args[1].len > 0) args[1] else if (args.len > 0 and args[0].len > 0) args[0] else call.kind;
            const parent = if (cluster_stack.items.len > 0) cluster_stack.items[cluster_stack.items.len - 1] else fc.NO_CLUSTER;
            try clusters.append(arena, .{ .title = ttl, .parent = parent });
            try cluster_stack.append(arena, clusters.items.len - 1);
            continue;
        }

        const call = splitCall(t) orelse continue;
        const args = try parseArgs(arena, call.inner);

        // Relationship? (startsWith also catches Rel_U/D/L/R and BiRel_U/D/L/R.)
        if (std.mem.startsWith(u8, call.kind, "Rel") or std.mem.startsWith(u8, call.kind, "BiRel")) {
            if (args.len < 2 or args[0].len == 0 or args[1].len == 0) continue;
            var a = args[0];
            var b = args[1];
            if (std.mem.eql(u8, call.kind, "Rel_Back")) {
                const tmp = a;
                a = b;
                b = tmp;
            }
            var label: []const u8 = if (args.len > 2) args[2] else "";
            if (dynamic) {
                rel_no += 1;
                label = try std.fmt.allocPrint(arena, "{d}. {s}", .{ rel_no, label });
            }
            const fi = try st.ensure(a, .{ .label = a });
            const ti = try st.ensure(b, .{ .label = b });
            try edges.append(arena, .{ .from = fi, .to = ti, .label = label, .bidir = std.mem.startsWith(u8, call.kind, "BiRel") });
            continue;
        }

        // Element node: arg0 = id, arg1 = label, rest = technology/description.
        const id = args[0];
        if (id.len == 0) continue;
        const lbl = if (args.len > 1 and args[1].len > 0) args[1] else id;
        const ni = try st.ensure(id, .{ .label = id });
        st.items.items[ni].label = lbl;
        if (cluster_stack.items.len > 0) {
            try node_cluster.put(id, cluster_stack.items[cluster_stack.items.len - 1]);
        }
        const gop = try bodies.getOrPut(id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        gop.value_ptr.clearRetainingCapacity();
        try gop.value_ptr.append(arena, try std.fmt.allocPrint(arena, "<<{s}>>", .{call.kind}));
        var ai: usize = 2;
        while (ai < args.len) : (ai += 1) {
            const ex = args[ai];
            if (ex.len == 0 or ex[0] == '$') continue; // skip named params ($tags/$link)
            try gop.value_ptr.append(arena, ex);
        }
    }
    if (st.items.items.len == 0) return error.Empty;

    for (st.ids.items, 0..) |id, i| {
        if (bodies.get(id)) |list| st.items.items[i].body = list.items;
    }

    const art = if (clusters.items.len > 0) blk: {
        const nc = try arena.alloc(usize, st.ids.items.len);
        for (st.ids.items, 0..) |id, i| nc[i] = node_cluster.get(id) orelse fc.NO_CLUSTER;
        break :blk try fc.layoutClustered(arena, st.items.items, edges.items, .td, ascii, nc, clusters.items);
    } else try fc.layout(arena, st.items.items, edges.items, .td, ascii);

    if (title.len > 0) return std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ title, art });
    return art;
}

const Call = struct { kind: []const u8, inner: []const u8 };

/// `Kind(args...)` into the keyword and the raw argument list, scanning to the
/// matching `)` and ignoring parens inside quotes. Null when there is no call, or
/// when the keyword carries whitespace (then it is not a C4 statement).
fn splitCall(t: []const u8) ?Call {
    const ip = std.mem.indexOfScalar(u8, t, '(') orelse return null;
    const kind = std.mem.trim(u8, t[0..ip], ws);
    if (kind.len == 0 or std.mem.indexOfAny(u8, kind, " \t") != null) return null;
    var depth: usize = 1;
    var in_q = false;
    var i = ip + 1;
    while (i < t.len) : (i += 1) {
        const c = t[i];
        if (c == '"') {
            in_q = !in_q;
        } else if (!in_q and c == '(') {
            depth += 1;
        } else if (!in_q and c == ')') {
            depth -= 1;
            if (depth == 0) return .{ .kind = kind, .inner = t[ip + 1 .. i] };
        }
    }
    return null;
}

/// Splits on top-level commas, keeping those inside `"..."`, then trims and unquotes
/// each argument. Always at least one element, possibly empty.
fn parseArgs(arena: std.mem.Allocator, inner: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var in_q = false;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        const c = inner[i];
        if (c == '"') {
            in_q = !in_q;
        } else if (c == ',' and !in_q) {
            try list.append(arena, cleanArg(inner[start..i]));
            start = i + 1;
        }
    }
    try list.append(arena, cleanArg(inner[start..]));
    return list.items;
}

fn cleanArg(s0: []const u8) []const u8 {
    var s = std.mem.trim(u8, s0, ws);
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') s = s[1 .. s.len - 1];
    return std.mem.trim(u8, s, ws);
}

const firstWord = text.firstWord;

const eqIgnoreCase = text.eqIgnoreCase;

test "c4 context renders elements, stereotypes, relations and title" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "C4Context\n" ++
        "title System Context diagram for Internet Banking\n" ++
        "Person(customerA, \"Banking Customer A\", \"A customer of the bank.\")\n" ++
        "System(SystemAA, \"Internet Banking System\", \"Allows customers to view info.\")\n" ++
        "System_Ext(SystemE, \"Mail System\", \"Microsoft Exchange.\")\n" ++
        "Rel(customerA, SystemAA, \"Uses\")\n" ++
        "Rel(SystemAA, SystemE, \"Sends e-mails\", \"SMTP\")\n";
    const art = try render(arena.allocator(), src, true);
    for ([_][]const u8{
        "System Context diagram for Internet Banking", // title
        "Banking Customer A",
        "Internet Banking System",
        "Mail System",    "A customer of the bank.", // description body
        "<<System_Ext>>", "Uses",
        "Sends e-mails",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, art, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, art, "v") != null); // ascii down arrow (TD)
}

test "c4 deployment groups containers in a titled deployment node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "C4Deployment\n" ++
        "Deployment_Node(aws, \"Amazon Web Services\", \"us-east-1\") {\n" ++
        "  Container(api, \"API Application\", \"Java\", \"Banking API\")\n" ++
        "  ContainerDb(db, \"Database\", \"Oracle\", \"Stores accounts\")\n" ++
        "}\n";
    const art = try render(arena.allocator(), src, true);
    for ([_][]const u8{
        "Amazon Web Services", // deployment node → titled cluster box
        "API Application",
        "Database",
        "<<ContainerDb>>",
        "Banking API",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, art, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, art, "+") != null); // ascii box corners
}

test "c4 BiRel draws arrowheads at both ends" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "C4Context\n" ++
        "System(a, \"Billing\")\n" ++
        "System(b, \"Ledger\")\n" ++
        "BiRel(a, b, \"Syncs with\")\n";
    const art = try render(arena.allocator(), src, true);
    // TD layout: forward head enters the dest from above (v), the source-end
    // head points back up into the source (^).
    try std.testing.expect(std.mem.indexOf(u8, art, "v") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "^") != null);
}

test "c4 dynamic numbers relationships in order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "C4Dynamic\n" ++
        "Container(c1, \"SPA\", \"Angular\")\n" ++
        "Container(c2, \"API\", \"Java\")\n" ++
        "Container(c3, \"DB\", \"SQL\")\n" ++
        "Rel(c1, c2, \"Submits credentials to\")\n" ++
        "Rel(c2, c3, \"Reads from\")\n";
    const art = try render(arena.allocator(), src, true);
    // Edge labels are clipped to the column gap by the engine, so assert on the
    // numbering prefixes (intent: relationships numbered in source order).
    try std.testing.expect(std.mem.indexOf(u8, art, "1. Submits") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "2. Reads from") != null);
}

test "c4 splitCall extracts kind and inner, ignoring parens inside quotes" {
    const a = splitCall("Person(user, \"User\")").?;
    try std.testing.expectEqualStrings("Person", a.kind);
    try std.testing.expectEqualStrings("user, \"User\"", a.inner);
    const b = splitCall("Rel(a, \"uses (v2)\")").?;
    try std.testing.expectEqualStrings("Rel", b.kind);
    try std.testing.expectEqualStrings("a, \"uses (v2)\"", b.inner);
    try std.testing.expect(splitCall("plain text") == null); // no '('
    try std.testing.expect(splitCall("has space (x)") == null); // kind must be a single token
}

test "c4 cleanArg trims whitespace and unwraps surrounding quotes" {
    try std.testing.expectEqualStrings("User", cleanArg("  \"User\"  "));
    try std.testing.expectEqualStrings("user", cleanArg("user"));
    try std.testing.expectEqualStrings("x", cleanArg("  x  "));
}
