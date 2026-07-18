//! Syntax Ref: https://mermaid.ai/open-source/syntax/requirementDiagram.html
//!
//! Requirement diagram: requirements/elements mapped onto the flowchart engine.
//! Each requirement/element becomes a box with a `<<kind>>` stereotype body.
//! Relationships (satisfies/derives/contains...) become labelled edges.

const std = @import("std");
const fc = @import("flowchart.zig");
const text = @import("text.zig");

const ws = text.ws;
const eqIgnoreCase = text.eqIgnoreCase;
const addMember = text.addMember;

const Rel = struct { from: []const u8, to: []const u8, label: []const u8 };

const req_kinds = [_][]const u8{
    "requirement",            "functionalRequirement", "interfaceRequirement",
    "performanceRequirement", "physicalRequirement",   "designConstraint",
    "element",
};

const ReqOpen = struct { kind: []const u8, name: []const u8 };

/// `<kind> <name> {`, the block declaring a requirement or element.
fn reqOpener(t: []const u8) ?ReqOpen {
    for (req_kinds) |k| {
        if (std.mem.startsWith(u8, t, k) and t.len > k.len and (t[k.len] == ' ' or t[k.len] == '\t')) {
            var rest = std.mem.trim(u8, t[k.len..], ws);
            if (!std.mem.endsWith(u8, rest, "{")) return null;
            rest = std.mem.trim(u8, rest[0 .. rest.len - 1], ws);
            if (rest.len == 0) return null;
            return .{ .kind = k, .name = rest };
        }
    }
    return null;
}

/// `A - verb -> B` or `B <- verb - A`, verb being the relationship type
/// (satisfies/derives/contains and friends). Direction follows the arrowhead.
fn findReqRel(t: []const u8) ?Rel {
    if (std.mem.indexOf(u8, t, "->")) |ar| {
        const sep = std.mem.indexOf(u8, t[0..ar], " - ") orelse return null;
        const from = std.mem.trim(u8, t[0..sep], ws);
        const verb = std.mem.trim(u8, t[sep + 3 .. ar], ws);
        const to = std.mem.trim(u8, t[ar + 2 ..], ws);
        if (from.len == 0 or to.len == 0) return null;
        return .{ .from = from, .to = to, .label = verb };
    }
    if (std.mem.indexOf(u8, t, "<-")) |al| {
        const to = std.mem.trim(u8, t[0..al], ws);
        const rest = t[al + 2 ..];
        const sep = std.mem.indexOf(u8, rest, " - ") orelse return null;
        const verb = std.mem.trim(u8, rest[0..sep], ws);
        const from = std.mem.trim(u8, rest[sep + 3 ..], ws);
        if (from.len == 0 or to.len == 0) return null;
        return .{ .from = from, .to = to, .label = verb };
    }
    return null;
}

pub fn render(arena: std.mem.Allocator, src: []const u8, ascii: bool, graph_dir: []const u8) ![]const u8 {
    var st = text.Interner(fc.Node).init(arena);
    var edges: std.ArrayList(fc.Edge) = .empty;
    var members: std.StringHashMap(std.ArrayList([]const u8)) = .init(arena);
    var current: []const u8 = ""; // requirement/element whose `{ ... }` body we're in
    var dir: fc.Dir = .td;

    var it = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, ws);
        if (first) {
            first = false;
            continue; // skip "requirementDiagram"
        }
        if (t.len == 0 or std.mem.startsWith(u8, t, "%%")) continue;
        if (std.mem.eql(u8, t, "}")) {
            current = "";
            continue;
        }
        if (current.len > 0) {
            try addMember(arena, &members, current, t);
            continue;
        }
        if (reqOpener(t)) |ro| {
            _ = try st.ensure(ro.name, .{ .label = ro.name });
            try addMember(arena, &members, ro.name, try std.fmt.allocPrint(arena, "<<{s}>>", .{ro.kind}));
            current = ro.name;
            continue;
        }
        if (findReqRel(t)) |r| {
            const fi = try st.ensure(r.from, .{ .label = r.from });
            const ti = try st.ensure(r.to, .{ .label = r.to });
            try edges.append(arena, .{ .from = fi, .to = ti, .label = r.label });
        }
    }
    if (st.items.items.len == 0) return error.Empty;
    for (st.ids.items, 0..) |id, i| {
        if (members.get(id)) |list| st.items.items[i].body = list.items;
    }
    if (eqIgnoreCase(graph_dir, "LR")) dir = .lr;
    if (eqIgnoreCase(graph_dir, "TD")) dir = .td;
    return fc.layout(arena, st.items.items, edges.items, dir, ascii);
}

test "reqOpener needs a kind keyword and a trailing brace" {
    const ro = reqOpener("requirement Login {").?;
    try std.testing.expectEqualStrings("requirement", ro.kind);
    try std.testing.expectEqualStrings("Login", ro.name);
    try std.testing.expect(reqOpener("requirement Login") == null); // no brace
    try std.testing.expect(reqOpener("banana Login {") == null); // not a known kind
}

test "findReqRel reads both arrow directions with the verb as label" {
    const r = findReqRel("logic - satisfies -> req").?;
    try std.testing.expectEqualStrings("logic", r.from);
    try std.testing.expectEqualStrings("req", r.to);
    try std.testing.expectEqualStrings("satisfies", r.label);
    const b = findReqRel("req <- derives - other").?;
    try std.testing.expectEqualStrings("other", b.from);
    try std.testing.expectEqualStrings("req", b.to);
    try std.testing.expectEqualStrings("derives", b.label);
}
