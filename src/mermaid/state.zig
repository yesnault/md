//! Syntax Ref: https://mermaid.ai/open-source/syntax/stateDiagram.html
//!
//! State diagram, translated to the flowchart engine.
//!
//! Composite states (`state X { ... }`) map onto the engine's clusters, like
//! `subgraph` and the C4 boundaries. The engine has no cluster-border edges,
//! so an edge naming a composite is retargeted to a representative inner
//! state: its scoped `[*]` start when entering, its end when leaving, else
//! its first member. Concurrency separators (`--` regions) are ignored.

const std = @import("std");
const fc = @import("flowchart.zig");
const text = @import("text.zig");

const ws = text.ws;
const eqIgnoreCase = text.eqIgnoreCase;

const Edge = struct { from: []const u8, to: []const u8, label: []const u8 };

/// ClusterRep tracks the representative states of one composite.
const ClusterRep = struct { first: ?[]const u8 = null, start: ?[]const u8 = null, end: ?[]const u8 = null };

/// StateClusters is the composite bookkeeping of the state parser.
const StateClusters = struct {
    arena: std.mem.Allocator,
    list: std.ArrayList(fc.Cluster) = .empty,
    stack: std.ArrayList(usize) = .empty,
    membership: std.StringHashMap(usize), // node id → innermost cluster
    composite_of: std.StringHashMap(usize), // composite id → its cluster
    reps: std.ArrayList(ClusterRep) = .empty,

    fn init(arena: std.mem.Allocator) StateClusters {
        return .{ .arena = arena, .membership = .init(arena), .composite_of = .init(arena) };
    }

    fn top(self: *StateClusters) ?usize {
        return if (self.stack.items.len > 0) self.stack.items[self.stack.items.len - 1] else null;
    }

    fn open(self: *StateClusters, id: []const u8, title: []const u8) !void {
        try self.list.append(self.arena, .{ .title = title, .parent = self.top() orelse fc.NO_CLUSTER });
        try self.reps.append(self.arena, .{});
        try self.composite_of.put(id, self.list.items.len - 1);
        try self.stack.append(self.arena, self.list.items.len - 1);
    }

    fn close(self: *StateClusters) void {
        if (self.stack.items.len > 0) _ = self.stack.pop();
    }

    /// Records `id` in the current composite (first-wins, like the flowchart parser)
    /// and as its first-member fallback for border edges.
    fn member(self: *StateClusters, id: []const u8) !void {
        const cur = self.top() orelse return;
        if (!self.membership.contains(id)) try self.membership.put(id, cur);
        const rep = &self.reps.items[cur];
        if (rep.first == null and !self.composite_of.contains(id)) rep.first = id;
    }

    /// The `[*]` pseudo-state id for the current scope: shared and top-level outside
    /// composites, per-cluster inside one.
    fn pseudo(self: *StateClusters, comptime kind: []const u8) ![]const u8 {
        const cur = self.top() orelse return "\x00" ++ kind;
        const rep = &self.reps.items[cur];
        const slot = if (comptime std.mem.eql(u8, kind, "start")) &rep.start else &rep.end;
        if (slot.*) |id| return id;
        const id = try std.fmt.allocPrint(self.arena, "\x00" ++ kind ++ "{d}", .{cur});
        slot.* = id;
        try self.membership.put(id, cur);
        return id;
    }

    /// Retargets an endpoint naming a composite to a representative inner state,
    /// following composites nested in the representative chain. Null for (chains of)
    /// empty composites.
    fn resolve(self: *StateClusters, id0: []const u8, entering: bool) ?[]const u8 {
        var id = id0;
        var hops: usize = 0;
        while (self.composite_of.get(id)) |ci| {
            const rep = self.reps.items[ci];
            id = (if (entering) rep.start orelse rep.first else rep.end orelse rep.first) orelse return null;
            hops += 1;
            if (hops > self.reps.items.len) return null; // defensive: cyclic chain
        }
        return id;
    }
};

pub fn render(arena: std.mem.Allocator, src: []const u8, ascii: bool, graph_dir: []const u8) ![]const u8 {
    var st = text.Interner(fc.Node).init(arena);
    var labels: std.StringHashMap([]const u8) = .init(arena);
    var raw_edges: std.ArrayList(Edge) = .empty; // deferred: a composite may be declared after use
    var cl = StateClusters.init(arena);
    var dir: fc.Dir = .td;

    var it = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, ws);
        if (first) {
            first = false;
            continue; // skip "stateDiagram" / "stateDiagram-v2"
        }
        if (t.len == 0 or std.mem.startsWith(u8, t, "%%")) continue;
        if (std.mem.startsWith(u8, t, "note")) continue;
        if (std.mem.eql(u8, t, "}")) {
            cl.close();
            continue;
        }
        if (std.mem.startsWith(u8, t, "direction ")) {
            const d = std.mem.trim(u8, t[10..], ws);
            if (eqIgnoreCase(d, "LR") or eqIgnoreCase(d, "RL")) dir = .lr;
            continue;
        }
        if (std.mem.startsWith(u8, t, "state ")) {
            var rest = std.mem.trim(u8, t[6..], ws);
            const opens = std.mem.endsWith(u8, rest, "{");
            if (opens) rest = std.mem.trim(u8, rest[0 .. rest.len - 1], ws);
            var id = rest;
            var desc: []const u8 = "";
            if (std.mem.indexOf(u8, rest, " as ")) |i| {
                desc = std.mem.trim(u8, std.mem.trim(u8, rest[0..i], ws), "\"");
                id = std.mem.trim(u8, rest[i + 4 ..], ws);
            }
            if (id.len == 0) continue;
            if (opens) {
                try cl.open(id, if (desc.len > 0) desc else id);
            } else {
                _ = try st.ensure(id, .{ .label = id });
                if (desc.len > 0) try labels.put(id, desc);
                try cl.member(id);
            }
            continue;
        }
        if (std.mem.indexOf(u8, t, "-->")) |ai| {
            const left = std.mem.trim(u8, t[0..ai], ws);
            var rightpart = std.mem.trim(u8, t[ai + 3 ..], ws);
            var label: []const u8 = "";
            if (std.mem.indexOfScalar(u8, rightpart, ':')) |ci| {
                label = std.mem.trim(u8, rightpart[ci + 1 ..], ws);
                rightpart = std.mem.trim(u8, rightpart[0..ci], ws);
            }
            // `[*]` is a start on the from side, an end on the to side, both
            // scoped to the innermost composite.
            const fromid = if (std.mem.eql(u8, left, "[*]")) try cl.pseudo("start") else left;
            const toid = if (std.mem.eql(u8, rightpart, "[*]")) try cl.pseudo("end") else rightpart;
            if (!std.mem.eql(u8, left, "[*]")) try cl.member(left);
            if (!std.mem.eql(u8, rightpart, "[*]")) try cl.member(rightpart);
            try raw_edges.append(arena, .{ .from = fromid, .to = toid, .label = label });
        }
    }

    // Resolve the deferred edges: endpoints naming a composite retarget to a
    // representative inner state. Edges on empty composites are dropped.
    var edges: std.ArrayList(fc.Edge) = .empty;
    for (raw_edges.items) |e| {
        const from = cl.resolve(e.from, false) orelse continue;
        const to = cl.resolve(e.to, true) orelse continue;
        const fi = try st.ensure(from, .{ .label = from });
        const ti = try st.ensure(to, .{ .label = to });
        try edges.append(arena, .{ .from = fi, .to = ti, .label = e.label });
    }
    if (st.items.items.len == 0) return error.Empty;

    // Resolve labels: pseudo-states as a filled dot, declared states by desc.
    const dot: []const u8 = if (ascii) "(*)" else "\u{25CF}"; // ●
    for (st.ids.items, 0..) |id, i| {
        if (id.len > 0 and id[0] == 0) {
            st.items.items[i].label = dot;
        } else if (labels.get(id)) |d| {
            st.items.items[i].label = d;
        }
    }
    if (eqIgnoreCase(graph_dir, "LR")) dir = .lr;
    if (eqIgnoreCase(graph_dir, "TD")) dir = .td;

    if (cl.list.items.len > 0) {
        const node_cluster = try arena.alloc(usize, st.ids.items.len);
        for (st.ids.items, 0..) |id, i| node_cluster[i] = cl.membership.get(id) orelse fc.NO_CLUSTER;
        return fc.layoutClustered(arena, st.items.items, edges.items, dir, ascii, node_cluster, cl.list.items);
    }
    return fc.layout(arena, st.items.items, edges.items, dir, ascii);
}
