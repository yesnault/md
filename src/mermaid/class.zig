//! Syntax Ref (classDiagram): https://mermaid.ai/open-source/syntax/classDiagram.html
//! Syntax Ref (erDiagram): https://mermaid.ai/open-source/syntax/entityRelationshipDiagram.html
//!
//! Class and ER diagrams: relationships mapped onto the flowchart engine. One
//! parser serves both. The dispatcher picks the default direction (class → TD,
//! ER → LR). Elements become boxes with a member/attribute body, relationships
//! become edges.

const std = @import("std");
const fc = @import("flowchart.zig");
const text = @import("text.zig");

const ws = text.ws;
const eqIgnoreCase = text.eqIgnoreCase;
const addMember = text.addMember;

const Rel = struct { from: []const u8, to: []const u8, label: []const u8 };

pub fn render(arena: std.mem.Allocator, src: []const u8, ascii: bool, graph_dir: []const u8, default_dir: fc.Dir) ![]const u8 {
    var st = text.Interner(fc.Node).init(arena);
    var edges: std.ArrayList(fc.Edge) = .empty;
    var members: std.StringHashMap(std.ArrayList([]const u8)) = .init(arena);
    var current: []const u8 = ""; // entity whose `{ ... }` body we're inside
    var dir = default_dir;

    var it = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, ws);
        if (first) {
            first = false;
            continue;
        }
        if (t.len == 0 or std.mem.startsWith(u8, t, "%%")) continue;
        if (std.mem.eql(u8, t, "}")) {
            current = "";
            continue;
        }
        // Inside a class/entity body: every line is a member/attribute.
        if (current.len > 0) {
            try addMember(arena, &members, current, t);
            continue;
        }
        if (std.mem.startsWith(u8, t, "note")) continue;
        if (std.mem.startsWith(u8, t, "direction ")) {
            const d = std.mem.trim(u8, t[10..], ws);
            if (eqIgnoreCase(d, "LR") or eqIgnoreCase(d, "RL")) dir = .lr;
            if (eqIgnoreCase(d, "TD") or eqIgnoreCase(d, "TB")) dir = .td;
            continue;
        }
        // Relationships first (ER crow's-foot ops like ||--o{ contain '{').
        if (findRel(t)) |r| {
            const fi = try st.ensure(r.from, .{ .label = r.from });
            const ti = try st.ensure(r.to, .{ .label = r.to });
            try edges.append(arena, .{ .from = fi, .to = ti, .label = r.label });
            continue;
        }
        // A block opener "class Foo {" or "ENTITY {": register the type, then
        // capture its body (multi-line until `}`, or inline `{ member }`).
        if (std.mem.indexOfScalar(u8, t, '{')) |bi| {
            const id = entityId(stripClassKw(std.mem.trim(u8, t[0..bi], ws)));
            if (id.len > 0) {
                _ = try st.ensure(id, .{ .label = id });
                const after = std.mem.trim(u8, t[bi + 1 ..], ws);
                if (std.mem.indexOfScalar(u8, after, '}')) |cj| {
                    const inner = std.mem.trim(u8, after[0..cj], ws);
                    if (inner.len > 0) try addMember(arena, &members, id, inner);
                } else {
                    if (after.len > 0) try addMember(arena, &members, id, after);
                    current = id;
                }
            }
            continue;
        }
        // "class Foo" declaration, or a member line "Foo : +bar" → register Foo
        // and record the member.
        if (std.mem.startsWith(u8, t, "class ")) {
            const id = entityId(stripClassKw(t));
            if (id.len > 0) _ = try st.ensure(id, .{ .label = id });
        } else if (std.mem.indexOfScalar(u8, t, ':')) |ci| {
            const id = entityId(std.mem.trim(u8, t[0..ci], ws));
            if (id.len > 0) {
                _ = try st.ensure(id, .{ .label = id });
                const m = std.mem.trim(u8, t[ci + 1 ..], ws);
                if (m.len > 0) try addMember(arena, &members, id, m);
            }
        }
    }
    if (st.items.items.len == 0) return error.Empty;
    // Attach collected bodies to their nodes.
    for (st.ids.items, 0..) |id, i| {
        if (members.get(id)) |list| st.items.items[i].body = list.items;
    }
    if (eqIgnoreCase(graph_dir, "LR")) dir = .lr;
    if (eqIgnoreCase(graph_dir, "TD")) dir = .td;
    return fc.layout(arena, st.items.items, edges.items, dir, ascii);
}

fn stripClassKw(s: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, s, "class ")) std.mem.trim(u8, s[6..], ws) else s;
}

/// The identifier from one side of a relationship, skipping a leading quoted
/// cardinality ("1", "*") and a trailing class style (:::name).
fn entityId(part: []const u8) []const u8 {
    var s = std.mem.trim(u8, part, ws);
    if (s.len > 0 and s[0] == '"') {
        if (std.mem.indexOfScalarPos(u8, s, 1, '"')) |q| s = std.mem.trim(u8, s[q + 1 ..], ws);
    }
    const end = std.mem.indexOfAny(u8, s, " \t") orelse s.len;
    s = s[0..end];
    if (std.mem.indexOf(u8, s, ":::")) |st| s = s[0..st];
    return s;
}

const arrow_chars = "<>|*o{}";

fn inArrowSet(ch: u8) bool {
    return std.mem.indexOfScalar(u8, arrow_chars, ch) != null;
}

/// `LEFT <op> RIGHT [: label]`, op being a class/ER relationship (it contains `--`
/// or `..`, with optional arrow/crow's-foot decorations). Edge direction follows the
/// arrowhead side. Null for non-relationship lines.
fn findRel(t: []const u8) ?Rel {
    const core = std.mem.indexOf(u8, t, "--") orelse std.mem.indexOf(u8, t, "..") orelse return null;
    // A ':' before the connector means this is a member/label line, not a relation.
    if (std.mem.indexOfScalar(u8, t, ':')) |ci| {
        if (ci < core) return null;
    }
    var os = core;
    while (os > 0 and inArrowSet(t[os - 1])) os -= 1;
    var oe = core;
    while (oe < t.len and (t[oe] == '-' or t[oe] == '.')) oe += 1;
    while (oe < t.len and inArrowSet(t[oe])) oe += 1;
    const op = t[os..oe];

    const left = entityId(std.mem.trim(u8, t[0..os], ws));
    var rightpart = std.mem.trim(u8, t[oe..], ws);
    var label: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rightpart, ':')) |li| {
        label = std.mem.trim(u8, rightpart[li + 1 ..], ws);
        rightpart = std.mem.trim(u8, rightpart[0..li], ws);
    }
    const right = entityId(rightpart);
    if (left.len == 0 or right.len == 0) return null;

    const left_arrow = op.len > 0 and op[0] == '<';
    const right_arrow = op.len > 0 and op[op.len - 1] == '>';
    if (left_arrow and !right_arrow) return .{ .from = right, .to = left, .label = label };
    return .{ .from = left, .to = right, .label = label };
}

test "stripClassKw drops a leading class keyword" {
    try std.testing.expectEqualStrings("Foo", stripClassKw("class Foo"));
    try std.testing.expectEqualStrings("Foo", stripClassKw("Foo"));
}

test "entityId strips a quoted cardinality and a :::class suffix" {
    try std.testing.expectEqualStrings("Order", entityId("\"1\" Order"));
    try std.testing.expectEqualStrings("Order", entityId("Order:::hot"));
    try std.testing.expectEqualStrings("Customer", entityId("Customer"));
}

test "inArrowSet recognises relationship decoration chars" {
    try std.testing.expect(inArrowSet('<') and inArrowSet('|') and inArrowSet('o') and inArrowSet('{'));
    try std.testing.expect(!inArrowSet('a') and !inArrowSet('-'));
}

test "findRel keeps ER direction and reads the label" {
    const r = findRel("Customer ||--o{ Order : places").?;
    try std.testing.expectEqualStrings("Customer", r.from);
    try std.testing.expectEqualStrings("Order", r.to);
    try std.testing.expectEqualStrings("places", r.label);
}

test "findRel flips direction when the arrowhead points left" {
    const r = findRel("Dog <|-- Animal").?;
    // arrowhead on the left, so the source is the right side
    try std.testing.expectEqualStrings("Animal", r.from);
    try std.testing.expectEqualStrings("Dog", r.to);
}

test "findRel ignores a line whose colon precedes the connector" {
    try std.testing.expect(findRel("count : int -- legacy") == null);
}
