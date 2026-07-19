//! Syntax Ref: https://mermaid.ai/open-source/syntax/flowchart.html
//!
//! Layered 2D layout for Mermaid flowcharts: rank, order, route. TD/TB and LR/RL.
//!
//! Clusters reserve real columns for their borders (dagre-style border dummies).
//! That is what keeps foreign nodes and edge chains out of the box.

const std = @import("std");
const Canvas = @import("canvas.zig").Canvas;
const putCentered = @import("canvas.zig").putCentered;
const width = @import("../markdown/width.zig");
const theme = @import("../theme.zig");
const text = @import("text.zig");
const ws = text.ws;
const eqIgnoreCase = text.eqIgnoreCase;

pub const Dir = enum { td, lr };

/// Node border shape (mapped from Mermaid node-shape syntax). Shapes collapse to
/// three drawable border styles: sharp, rounded, and angled corners.
pub const Shape = enum { rect, round, stadium, circle, subroutine, cylinder, rhombus, hexagon, parallelogram, asymmetric };

/// A node renders as a box. `body` lines (e.g. class members / ER attributes),
/// when non-empty, add a divider compartment below the title. `style` colours the
/// box (from classDef/style). `shape` selects the border style.
pub const Node = struct {
    label: []const u8,
    body: []const []const u8 = &.{},
    shape: Shape = .rect,
    style: theme.Style = .{},
};
pub const Edge = struct {
    from: usize,
    to: usize,
    label: []const u8 = "",
    /// Bidirectional edges get an arrowhead at the source end too.
    bidir: bool = false,
};

const Glyphs = struct {
    tl: u21, // top-left     ┌
    tr: u21, // top-right    ┐
    bl: u21, // bottom-left  └
    br: u21, // bottom-right ┘
    te_l: u21, // left tee     ├ (compartment divider)
    te_r: u21, // right tee    ┤
    h: u21, // horizontal   ─
    v: u21, // vertical     │
    a_down: u21, // arrow down   ▼
    a_up: u21, // arrow up     ▲
    a_right: u21, // arrow right  ▶
    a_left: u21, // arrow left   ◀
};

const unicode_glyphs = Glyphs{
    .tl = '\u{250C}',
    .tr = '\u{2510}',
    .bl = '\u{2514}',
    .br = '\u{2518}', // ┌ ┐ └ ┘
    .te_l = '\u{251C}',
    .te_r = '\u{2524}', // ├ ┤
    .h = '\u{2500}',
    .v = '\u{2502}', // ─ │
    .a_down = '\u{25BC}',
    .a_up = '\u{25B2}',
    .a_right = '\u{25B6}',
    .a_left = '\u{25C0}', // ▼ ▲ ▶ ◀
};

const ascii_glyphs = Glyphs{
    .tl = '+',
    .tr = '+',
    .bl = '+',
    .br = '+',
    .te_l = '+',
    .te_r = '+',
    .h = '-',
    .v = '|',
    .a_down = 'v',
    .a_up = '^',
    .a_right = '>',
    .a_left = '<',
};

const box_h: usize = 3;
const gap_main: usize = 3; // rows/cols between rank bands
const gap_cross: usize = 3; // between boxes within a rank

/// A subgraph cluster. `parent` is the enclosing cluster index, or NO_CLUSTER.
pub const Cluster = struct { title: []const u8, parent: usize = NO_CLUSTER };
pub const NO_CLUSTER = std.math.maxInt(usize);

// Border-dummy role: none (real node / edge dummy), or the left/right border
// column (top/bottom row in LR) of a cluster.
const role_none: u8 = 0;
const role_bl: u8 = 1;
const role_br: u8 = 2;

const CBox = struct { x0: usize, y0: usize, x1: usize, y1: usize, title: []const u8, active: bool };

pub fn layout(arena: std.mem.Allocator, nodes: []const Node, edges: []const Edge, dir: Dir, ascii: bool) ![]const u8 {
    return layoutImpl(arena, nodes, edges, dir, ascii, &.{}, &.{});
}

/// Layout with subgraph clusters: `node_cluster[i]` is node i's innermost cluster
/// index (or NO_CLUSTER), and `clusters` carries titles/nesting.
pub fn layoutClustered(arena: std.mem.Allocator, nodes: []const Node, edges: []const Edge, dir: Dir, ascii: bool, node_cluster: []const usize, clusters: []const Cluster) ![]const u8 {
    return layoutImpl(arena, nodes, edges, dir, ascii, node_cluster, clusters);
}

fn layoutImpl(arena: std.mem.Allocator, nodes: []const Node, edges: []const Edge, dir: Dir, ascii: bool, node_cluster: []const usize, clusters: []const Cluster) ![]const u8 {
    if (nodes.len == 0) return error.Empty;
    var l = Layouter{
        .arena = arena,
        .nodes = nodes,
        .edges = edges,
        .dir = dir,
        .ascii = ascii,
        .node_cluster = node_cluster,
        .clusters = clusters,
        .n = nodes.len,
        .g = if (ascii) ascii_glyphs else unicode_glyphs,
    };
    try l.assignRanks();
    try l.buildDummies();
    try l.buildOrdering();
    try l.sizeBoxes();
    try l.initGeometry();
    if (dir == .td) try l.placeTd() else try l.placeLr();
    l.applyClusterMargin();
    try l.buildClusterBoxes();
    return l.draw();
}

/// Shared state of the layout pipeline. Each phase method fills the fields it
/// owns, in the order layoutImpl calls them. Later phases read earlier fields.
const Layouter = struct {
    arena: std.mem.Allocator,
    nodes: []const Node,
    edges: []const Edge,
    dir: Dir,
    ascii: bool,
    node_cluster: []const usize,
    clusters: []const Cluster,
    n: usize,
    g: Glyphs,

    // assignRanks
    is_back: []bool = &.{},
    rank: []usize = &.{}, // real nodes only, rankT also covers dummies
    nranks: usize = 1,

    // buildDummies
    rankT: []usize = &.{},
    edge_chain: [][]usize = &.{},
    ec: []usize = &.{}, // innermost cluster per extended node
    role: []u8 = &.{},
    bl0: []usize = &.{}, // first left-border dummy per cluster
    br0: []usize = &.{}, // first right-border dummy per cluster
    span_min: []usize = &.{},
    span_max: []usize = &.{},
    cactive: []bool = &.{},
    total: usize = 0,

    // buildOrdering
    members: []std.ArrayList(usize) = &.{},
    up: []std.ArrayList(usize) = &.{},
    down: []std.ArrayList(usize) = &.{},

    // sizeBoxes
    bw: []usize = &.{},
    bh: []usize = &.{},

    // initGeometry + placeTd/placeLr
    bx: []usize = &.{},
    by: []usize = &.{},
    rank_y: []usize = &.{},
    rank_h: []usize = &.{},
    colx: []usize = &.{},
    colw: []usize = &.{},
    jogs: []usize = &.{}, // routing line per inter-rank gap
    cs: []usize = &.{}, // clusters opening at rank r
    ce: []usize = &.{}, // clusters closing at rank r
    core_w: usize = 1,
    core_h: usize = 1,

    // buildClusterBoxes
    cboxes: []CBox = &.{},

    /// Breaks cycles (DFS back edges), then ranks the DAG by longest path. Without
    /// the cycle break, a loop would inflate ranks every iteration.
    fn assignRanks(self: *Layouter) !void {
        const n = self.n;
        const edges = self.edges;
        const is_back = try findBackEdges(self.arena, n, edges);

        const rank = try self.arena.alloc(usize, n);
        @memset(rank, 0);
        var iter: usize = 0;
        while (iter < n) : (iter += 1) {
            var changed = false;
            for (edges, 0..) |e, ei| {
                if (is_back[ei]) continue;
                if (e.from < n and e.to < n and rank[e.to] < rank[e.from] + 1) {
                    rank[e.to] = rank[e.from] + 1;
                    changed = true;
                }
            }
            if (!changed) break;
        }
        var nranks: usize = 1;
        for (rank) |r| nranks = @max(nranks, r + 1);

        self.is_back = is_back;
        self.rank = rank;
        self.nranks = nranks;
    }

    /// Virtual nodes: one per crossed rank on every long forward edge (so ordering
    /// and routing can thread each chain through its own column), plus two border
    /// dummies per cluster per spanned rank, reserving real columns (rows in LR)
    /// for the border.
    fn buildDummies(self: *Layouter) !void {
        const arena = self.arena;
        const n = self.n;
        const edges = self.edges;
        const rank = self.rank;
        const clusters = self.clusters;

        var rank_ext: std.ArrayList(usize) = .empty;
        try rank_ext.appendSlice(arena, rank);
        const edge_chain = try arena.alloc([]usize, edges.len);
        for (edges, 0..) |e, ei| {
            if (self.is_back[ei] or e.from >= n or e.to >= n or rank[e.to] <= rank[e.from]) {
                edge_chain[ei] = &.{};
                continue;
            }
            const rf = rank[e.from];
            const rt = rank[e.to];
            const ch = try arena.alloc(usize, rt - rf + 1);
            ch[0] = e.from;
            var r = rf + 1;
            var k: usize = 1;
            while (r < rt) : (r += 1) {
                try rank_ext.append(arena, r);
                ch[k] = rank_ext.items.len - 1;
                k += 1;
            }
            ch[k] = e.to;
            edge_chain[ei] = ch;
        }

        // Cluster per node (extended): reals from node_cluster, dummies inherit the
        // edge's cluster only when both endpoints share it (so the chain stays inside).
        var ec_list: std.ArrayList(usize) = .empty;
        for (0..rank_ext.items.len) |i| {
            try ec_list.append(arena, if (i < n and self.node_cluster.len > 0) self.node_cluster[i] else NO_CLUSTER);
        }
        for (edges, 0..) |e, ei| {
            const ch = edge_chain[ei];
            if (ch.len < 3) continue;
            const cc = if (e.from < n and e.to < n and ec_list.items[e.from] == ec_list.items[e.to]) ec_list.items[e.from] else NO_CLUSTER;
            for (ch[1 .. ch.len - 1]) |d| ec_list.items[d] = cc;
        }

        // Border dummies, ordered to the left/right extremes of the cluster's
        // group. They keep foreign nodes and edge chains outside the box and
        // sibling/nested borders from colliding.
        const ncl = clusters.len;
        const span_min = try arena.alloc(usize, ncl);
        const span_max = try arena.alloc(usize, ncl);
        const cactive = try arena.alloc(bool, ncl);
        @memset(cactive, false);
        for (ec_list.items, 0..) |c0, i| {
            var cc = c0;
            while (cc != NO_CLUSTER) : (cc = clusters[cc].parent) {
                const r = rank_ext.items[i];
                if (!cactive[cc]) {
                    cactive[cc] = true;
                    span_min[cc] = r;
                    span_max[cc] = r;
                } else {
                    span_min[cc] = @min(span_min[cc], r);
                    span_max[cc] = @max(span_max[cc], r);
                }
            }
        }
        var role_list: std.ArrayList(u8) = .empty;
        try role_list.appendNTimes(arena, role_none, ec_list.items.len);
        const bl0 = try arena.alloc(usize, ncl);
        const br0 = try arena.alloc(usize, ncl);
        for (0..ncl) |c| {
            if (!cactive[c]) continue;
            bl0[c] = rank_ext.items.len;
            var r = span_min[c];
            while (r <= span_max[c]) : (r += 1) {
                try rank_ext.append(arena, r);
                try ec_list.append(arena, c);
                try role_list.append(arena, role_bl);
            }
            br0[c] = rank_ext.items.len;
            r = span_min[c];
            while (r <= span_max[c]) : (r += 1) {
                try rank_ext.append(arena, r);
                try ec_list.append(arena, c);
                try role_list.append(arena, role_br);
            }
        }

        self.rankT = rank_ext.items;
        self.edge_chain = edge_chain;
        self.ec = ec_list.items;
        self.role = role_list.items;
        self.bl0 = bl0;
        self.br0 = br0;
        self.span_min = span_min;
        self.span_max = span_max;
        self.cactive = cactive;
        self.total = rank_ext.items.len;
    }

    fn buildOrdering(self: *Layouter) !void {
        const arena = self.arena;
        const total = self.total;

        // Rank membership (real + dummy) in insertion order, then crossing reduction.
        const members = try arena.alloc(std.ArrayList(usize), self.nranks);
        for (members) |*m| m.* = .empty;
        for (0..total) |i| try members[self.rankT[i]].append(arena, i);

        // Segment adjacency: consecutive-rank links along every chain.
        const up = try arena.alloc(std.ArrayList(usize), total);
        const down = try arena.alloc(std.ArrayList(usize), total);
        for (0..total) |i| {
            up[i] = .empty;
            down[i] = .empty;
        }
        for (self.edge_chain) |ch| {
            if (ch.len < 2) continue;
            for (0..ch.len - 1) |j| {
                try down[ch[j]].append(arena, ch[j + 1]);
                try up[ch[j + 1]].append(arena, ch[j]);
            }
        }
        // Border dummies chain vertically so Brandes-Köpf aligns each border straight
        // (dummy-dummy segments count as inner segments and get alignment priority).
        for (0..self.clusters.len) |c| {
            if (!self.cactive[c]) continue;
            for (0..self.span_max[c] - self.span_min[c]) |k| {
                try down[self.bl0[c] + k].append(arena, self.bl0[c] + k + 1);
                try up[self.bl0[c] + k + 1].append(arena, self.bl0[c] + k);
                try down[self.br0[c] + k].append(arena, self.br0[c] + k + 1);
                try up[self.br0[c] + k + 1].append(arena, self.br0[c] + k);
            }
        }
        try orderRanks(arena, total, self.nranks, members, up, down);
        if (self.clusters.len > 0) try enforceClusters(arena, total, self.nranks, members, self.ec, self.clusters, self.role);

        self.members = members;
        self.up = up;
        self.down = down;
    }

    /// Real nodes size to their content. Dummies are 1x1 routing cells. Reserves
    /// TD cluster-title width on the border dummies.
    fn sizeBoxes(self: *Layouter) !void {
        const n = self.n;
        const bw = try self.arena.alloc(usize, self.total);
        const bh = try self.arena.alloc(usize, self.total);
        for (0..self.total) |i| {
            if (i < n) {
                var maxc = width.displayWidth(self.nodes[i].label);
                for (self.nodes[i].body) |line| maxc = @max(maxc, width.displayWidth(line));
                bw[i] = @max(maxc + 4, 5); // 2 border cols + 1 pad each side
                bh[i] = if (self.nodes[i].body.len == 0) box_h else self.nodes[i].body.len + 4;
            } else {
                bw[i] = 1;
                bh[i] = 1;
            }
        }
        // A TD cluster title lies along the cross axis: split the title's width
        // over the border dummies so the layout reserves room for it (the box then
        // always fits its title without overlapping neighbours).
        if (self.dir == .td) {
            for (0..self.clusters.len) |c| {
                if (!self.cactive[c]) continue;
                const tw = width.displayWidth(self.clusters[c].title);
                if (tw == 0) continue;
                for (0..self.span_max[c] - self.span_min[c] + 1) |k| {
                    bw[self.bl0[c] + k] = tw / 2 + 2;
                    bw[self.br0[c] + k] = tw - tw / 2 + 2;
                }
            }
        }
        self.bw = bw;
        self.bh = bh;
    }

    /// Counts the cluster borders opening/closing at each rank boundary: each needs
    /// a reserved row (column in LR) in that gap, besides the routing jog line.
    fn initGeometry(self: *Layouter) !void {
        const arena = self.arena;
        const nranks = self.nranks;
        self.bx = try arena.alloc(usize, self.total);
        self.by = try arena.alloc(usize, self.total);
        self.rank_y = try arena.alloc(usize, nranks);
        self.rank_h = try arena.alloc(usize, nranks);
        self.colx = try arena.alloc(usize, nranks);
        self.colw = try arena.alloc(usize, nranks);
        self.jogs = try arena.alloc(usize, nranks);
        self.cs = try arena.alloc(usize, nranks + 1);
        self.ce = try arena.alloc(usize, nranks);
        @memset(self.cs, 0);
        @memset(self.ce, 0);
        for (0..self.clusters.len) |c| if (self.cactive[c]) {
            self.cs[self.span_min[c]] += 1;
            self.ce[self.span_max[c]] += 1;
        };
    }

    /// Rank bands stack vertically (height = tallest box, gap sized for the jog line
    /// plus cluster borders at the boundary). Cross axis from Brandes-Köpf.
    fn placeTd(self: *Layouter) !void {
        var yc: usize = 0;
        var last_gap: usize = 0;
        for (0..self.nranks) |r| {
            var mh: usize = box_h;
            for (self.members[r].items) |i| mh = @max(mh, self.bh[i]);
            self.rank_h[r] = mh;
            self.rank_y[r] = yc;
            const gap = @max(gap_main, self.ce[r] + 1 + self.cs[r + 1]);
            self.jogs[r] = yc + mh + self.ce[r] + (gap - self.ce[r] - self.cs[r + 1]) / 2;
            yc += mh + gap;
            last_gap = gap;
        }
        self.core_h = if (yc > last_gap) yc - last_gap else yc;
        for (0..self.nranks) |r| for (self.members[r].items) |i| {
            self.by[i] = self.rank_y[r] + (self.rank_h[r] - self.bh[i]) / 2; // center in the band
        };
        const xc = try assignCoords(self.arena, self.total, self.nranks, self.members, self.up, self.down, self.bw, gap_cross, self.n);
        for (0..self.total) |i| self.bx[i] = xc[i] - self.bw[i] / 2;
        for (0..self.total) |i| self.core_w = @max(self.core_w, self.bx[i] + self.bw[i]);
    }

    /// Columns advance horizontally (width = widest box, gap sized for jog, borders
    /// and forward-edge labels). Cross axis from Brandes-Köpf.
    fn placeLr(self: *Layouter) !void {
        for (0..self.nranks) |r| {
            var maxw: usize = 0;
            for (self.members[r].items) |i| maxw = @max(maxw, self.bw[i]);
            self.colw[r] = maxw;
        }
        // An LR cluster title lies along the main axis: widen the cluster's
        // last column when the title is wider than the columns it spans
        // (children first, so a parent sees its children's inflation).
        var ct = self.clusters.len;
        while (ct > 0) {
            ct -= 1;
            if (!self.cactive[ct]) continue;
            const tw = width.displayWidth(self.clusters[ct].title);
            if (tw == 0) continue;
            var avail: usize = 0;
            for (self.span_min[ct]..self.span_max[ct] + 1) |r| avail += self.colw[r];
            if (avail < tw + 4) self.colw[self.span_max[ct]] += tw + 4 - avail;
        }
        // LR forward-edge labels sit in the inter-column gap, so widen it to fit.
        var fwd_label_w: usize = 0;
        for (self.edges, 0..) |e, ei| {
            if (self.edge_chain[ei].len >= 2) fwd_label_w = @max(fwd_label_w, width.displayWidth(e.label));
        }
        const lr_gap = @max(gap_main + 1, fwd_label_w + 2);
        var cx: usize = 0;
        var last_gap: usize = 0;
        for (0..self.nranks) |r| {
            self.colx[r] = cx;
            // TODO: max, not sum, so a label wider than the borders keeps its own
            // gap and the cluster border rows eat the margin it was given: a long
            // label ends up flush against the border and the box beside it.
            const gap = @max(lr_gap, self.ce[r] + 1 + self.cs[r + 1]);
            self.jogs[r] = cx + self.colw[r] + self.ce[r] + (gap - self.ce[r] - self.cs[r + 1]) / 2;
            cx += self.colw[r] + gap;
            last_gap = gap;
        }
        self.core_w = if (cx > last_gap) cx - last_gap else cx;
        for (0..self.nranks) |r| for (self.members[r].items) |i| {
            self.bx[i] = self.colx[r];
        };
        const yc = try assignCoords(self.arena, self.total, self.nranks, self.members, self.up, self.down, self.bh, 1, self.n);
        for (0..self.total) |i| self.by[i] = yc[i] - self.bh[i] / 2;
        for (0..self.total) |i| self.core_h = @max(self.core_h, self.by[i] + self.bh[i]);
    }

    /// Shifts all geometry by the deepest active cluster chain (one row/column per
    /// nesting level), so the outermost border does not clip the drawing.
    fn applyClusterMargin(self: *Layouter) void {
        var maxdepth: usize = 0;
        for (0..self.clusters.len) |c| if (self.cactive[c]) {
            var d: usize = 0;
            var k = c;
            while (k != NO_CLUSTER) : (k = self.clusters[k].parent) d += 1;
            maxdepth = @max(maxdepth, d);
        };
        const margin = maxdepth;
        if (margin == 0) return;
        for (0..self.total) |i| {
            self.bx[i] += margin;
            self.by[i] += margin;
        }
        for (0..self.nranks) |r| {
            self.rank_y[r] += margin;
            self.colx[r] += margin;
            self.jogs[r] += margin;
        }
        self.core_w += 2 * margin;
        self.core_h += 2 * margin;
    }

    /// Each cluster's rectangle: cross axis from its border-dummy columns (rows in
    /// LR), main axis from the union of direct member boxes and child boxes, one
    /// cell further out per level. Clusters are appended parent-before-child, so a
    /// reverse scan sizes children first.
    fn buildClusterBoxes(self: *Layouter) !void {
        const ncl = self.clusters.len;
        const cboxes = try self.arena.alloc(CBox, ncl);
        var ci = ncl;
        while (ci > 0) {
            ci -= 1;
            cboxes[ci] = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0, .title = "", .active = false };
            if (!self.cactive[ci]) continue;
            var lo: usize = std.math.maxInt(usize); // main-axis union
            var hi: usize = 0;
            for (0..self.n) |i| {
                if (self.ec[i] != ci) continue;
                if (self.dir == .td) {
                    lo = @min(lo, self.by[i]);
                    hi = @max(hi, self.by[i] + self.bh[i] - 1);
                } else {
                    lo = @min(lo, self.bx[i]);
                    hi = @max(hi, self.bx[i] + self.bw[i] - 1);
                }
            }
            for (ci + 1..ncl) |d| {
                if (self.clusters[d].parent != ci or !cboxes[d].active) continue;
                if (self.dir == .td) {
                    lo = @min(lo, cboxes[d].y0);
                    hi = @max(hi, cboxes[d].y1);
                } else {
                    lo = @min(lo, cboxes[d].x0);
                    hi = @max(hi, cboxes[d].x1);
                }
            }
            if (lo == std.math.maxInt(usize)) continue;
            if (self.dir == .lr) {
                // The title reservation widened the last spanned column, not its
                // member boxes. Extend the union to the column's full width.
                hi = @max(hi, self.colx[self.span_max[ci]] + self.colw[self.span_max[ci]] - 1);
            }
            var b0: usize = std.math.maxInt(usize); // cross-axis border extremes
            var b1: usize = 0;
            for (0..self.span_max[ci] - self.span_min[ci] + 1) |k| {
                const cross_l = if (self.dir == .td) self.bx[self.bl0[ci] + k] else self.by[self.bl0[ci] + k];
                const cross_r = if (self.dir == .td) self.bx[self.br0[ci] + k] + self.bw[self.br0[ci] + k] - 1 else self.by[self.br0[ci] + k];
                b0 = @min(b0, cross_l);
                b1 = @max(b1, cross_r);
            }
            cboxes[ci] = if (self.dir == .td)
                .{ .x0 = b0, .y0 = lo - 1, .x1 = b1, .y1 = hi + 1, .title = self.clusters[ci].title, .active = true }
            else
                .{ .x0 = lo - 1, .y0 = b0, .x1 = hi + 1, .y1 = b1, .title = self.clusters[ci].title, .active = true };
        }
        self.cboxes = cboxes;
    }

    /// Sizes the canvas (reserving side lanes for back/same-rank edges), routes all
    /// edges, then draws cluster boxes over the edges (so titles survive the arrows)
    /// and nodes over everything.
    fn draw(self: *Layouter) ![]const u8 {
        const n = self.n;
        var nlanes: usize = 0;
        var back_label_w: usize = 0;
        for (self.edges, 0..) |e, ei| {
            if (e.from < n and e.to < n and self.edge_chain[ei].len < 2) {
                nlanes += 1;
                back_label_w = @max(back_label_w, width.displayWidth(e.label));
            }
        }
        var canvas_w = self.core_w;
        var canvas_h = self.core_h;
        // TD back-edge labels go in a far-right margin column past all lanes.
        const label_x = self.core_w + 2 + nlanes * 2 + 1;
        if (nlanes > 0) {
            if (self.dir == .td)
                canvas_w = self.core_w + 2 + nlanes * 2 + (if (back_label_w > 0) back_label_w + 1 else 0)
            else
                canvas_h = self.core_h + 2 + nlanes * 2;
        }
        for (self.cboxes) |cb| if (cb.active) {
            canvas_w = @max(canvas_w, cb.x1 + 1);
            canvas_h = @max(canvas_h, cb.y1 + 1);
        };

        var canvas = try Canvas.init(self.arena, canvas_w, canvas_h);

        var lane: usize = 0;
        for (self.edges, 0..) |e, ei| {
            const ch = self.edge_chain[ei];
            if (ch.len >= 2) {
                if (self.dir == .td)
                    routeChainTd(canvas, self.g, ch, self.bx, self.by, self.bw, self.bh, self.jogs, self.rankT, e.label, e.bidir)
                else
                    routeChainLr(canvas, self.g, ch, self.bx, self.by, self.bw, self.jogs, self.rankT, n, e.label, e.bidir);
            } else if (e.from < n and e.to < n) {
                const lane_pos = if (self.dir == .td) self.core_w + 2 + lane * 2 else self.core_h + 2 + lane * 2;
                if (self.dir == .td)
                    routeBackTd(canvas, self.g, self.bx[e.from], self.by[e.from], self.bw[e.from], self.bx[e.to], self.by[e.to], self.bw[e.to], lane_pos, e.label, label_x, e.bidir)
                else
                    routeBackLr(canvas, self.g, self.bx[e.from], self.by[e.from], self.bw[e.from], self.bh[e.from], self.bx[e.to], self.by[e.to], self.bw[e.to], self.bh[e.to], lane_pos, e.label, e.bidir);
                lane += 1;
            }
        }
        for (self.cboxes) |cb| if (cb.active) drawClusterBox(canvas, self.ascii, cb.x0, cb.y0, cb.x1, cb.y1, cb.title);
        for (self.nodes, 0..) |node, i| drawBox(canvas, self.g, self.bx[i], self.by[i], self.bw[i], node.shape, node.style, self.ascii, node.label, node.body);

        return canvas.toString(self.ascii);
    }
};

/// Marks edges pointing to an ancestor on the DFS stack, so ranking can treat the
/// graph as a DAG.
fn findBackEdges(arena: std.mem.Allocator, n: usize, edges: []const Edge) ![]bool {
    const out = try arena.alloc(std.ArrayList(usize), n);
    for (out) |*o| o.* = .empty;
    for (edges, 0..) |e, ei| {
        if (e.from < n and e.to < n) try out[e.from].append(arena, ei);
    }
    const is_back = try arena.alloc(bool, edges.len);
    @memset(is_back, false);
    const color = try arena.alloc(u8, n); // 0=white, 1=gray, 2=black
    @memset(color, 0);

    const Frame = struct { node: usize, next: usize };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(arena);
    for (0..n) |start| {
        if (color[start] != 0) continue;
        color[start] = 1;
        try stack.append(arena, .{ .node = start, .next = 0 });
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const oe = out[top.node].items;
            if (top.next < oe.len) {
                const ei = oe[top.next];
                top.next += 1;
                const v = edges[ei].to;
                if (v >= n) continue;
                if (color[v] == 1) {
                    is_back[ei] = true;
                } else if (color[v] == 0) {
                    color[v] = 1;
                    try stack.append(arena, .{ .node = v, .next = 0 });
                }
            } else {
                color[top.node] = 2;
                _ = stack.pop();
            }
        }
    }
    return is_back;
}

const Seg = struct { pu: usize, pv: usize };

/// Orders nodes within each rank to reduce edge crossings: repeated barycenter
/// sweeps plus adjacent-swap transposition. Keeps the best arrangement seen by
/// exact crossing count. The last sweep is not necessarily the best one.
fn orderRanks(arena: std.mem.Allocator, total: usize, nranks: usize, members: []std.ArrayList(usize), up: []std.ArrayList(usize), down: []std.ArrayList(usize)) !void {
    const pos = try arena.alloc(f64, total);
    const key = try arena.alloc(f64, total);
    const posi = try arena.alloc(usize, total);
    var segs: std.ArrayList(Seg) = .empty;

    const best = try arena.alloc([]usize, nranks);
    for (0..nranks) |r| best[r] = try arena.dupe(usize, members[r].items);
    var best_cost = countCrossings(arena, nranks, members, down, posi, &segs);

    syncPos(members, nranks, pos);
    var pass: usize = 0;
    while (pass < 8) : (pass += 1) {
        var r: usize = 1;
        while (r < nranks) : (r += 1) {
            for (members[r].items) |node| key[node] = median(up[node].items, pos);
            std.sort.insertion(usize, members[r].items, KeyCtx{ .key = key }, lessByKey);
            for (members[r].items, 0..) |node, i| pos[node] = @floatFromInt(i);
        }
        if (nranks >= 2) {
            var rr: usize = nranks - 1;
            while (rr > 0) {
                rr -= 1;
                for (members[rr].items) |node| key[node] = median(down[node].items, pos);
                std.sort.insertion(usize, members[rr].items, KeyCtx{ .key = key }, lessByKey);
                for (members[rr].items, 0..) |node, i| pos[node] = @floatFromInt(i);
            }
        }
        transpose(nranks, members, up, down, posi);
        syncPos(members, nranks, pos);
        const c = countCrossings(arena, nranks, members, down, posi, &segs);
        if (c < best_cost) {
            best_cost = c;
            for (0..nranks) |rb| @memcpy(best[rb], members[rb].items);
        }
        if (c == 0) break;
    }
    for (0..nranks) |r| @memcpy(members[r].items, best[r]);
}

fn syncPos(members: []std.ArrayList(usize), nranks: usize, pos: []f64) void {
    for (0..nranks) |r| for (members[r].items, 0..) |node, i| {
        pos[node] = @floatFromInt(i);
    };
}

/// Total edge-segment crossings across all adjacent rank pairs, exact.
fn countCrossings(arena: std.mem.Allocator, nranks: usize, members: []std.ArrayList(usize), down: []std.ArrayList(usize), posi: []usize, segs: *std.ArrayList(Seg)) usize {
    for (0..nranks) |r| for (members[r].items, 0..) |node, i| {
        posi[node] = i;
    };
    var total_c: usize = 0;
    if (nranks == 0) return 0;
    var r: usize = 0;
    while (r + 1 < nranks) : (r += 1) {
        segs.clearRetainingCapacity();
        for (members[r].items) |node| {
            for (down[node].items) |v| segs.append(arena, .{ .pu = posi[node], .pv = posi[v] }) catch return total_c;
        }
        const s = segs.items;
        for (s, 0..) |a, i| {
            for (s[i + 1 ..]) |b| {
                if ((a.pu < b.pu and a.pv > b.pv) or (a.pu > b.pu and a.pv < b.pv)) total_c += 1;
            }
        }
    }
    return total_c;
}

fn transpose(nranks: usize, members: []std.ArrayList(usize), up: []std.ArrayList(usize), down: []std.ArrayList(usize), posi: []usize) void {
    for (0..nranks) |r| for (members[r].items, 0..) |node, i| {
        posi[node] = i;
    };
    var changed = true;
    var guard: usize = 0;
    while (changed and guard < nranks + 4) : (guard += 1) {
        changed = false;
        for (0..nranks) |r| {
            const m = members[r].items;
            if (m.len < 2) continue;
            var i: usize = 0;
            while (i + 1 < m.len) : (i += 1) {
                const a = m[i];
                const b = m[i + 1];
                const cb = countGreater(up[a].items, up[b].items, posi) + countGreater(down[a].items, down[b].items, posi);
                const ca = countGreater(up[b].items, up[a].items, posi) + countGreater(down[b].items, down[a].items, posi);
                if (ca < cb) {
                    m[i] = b;
                    m[i + 1] = a;
                    posi[a] = i + 1;
                    posi[b] = i;
                    changed = true;
                }
            }
        }
    }
}

fn countGreater(a: []const usize, b: []const usize, posi: []const usize) usize {
    var c: usize = 0;
    for (a) |x| for (b) |y| {
        if (posi[x] > posi[y]) c += 1;
    };
    return c;
}

/// Reorders each rank so cluster contents are contiguous and wrapped by their
/// border dummies, nesting respected. Nodes sort by the mean position of each
/// cluster on their ancestry chain (root first). The bl/br borders bias to the extremes
/// of their own group, free nodes keep their barycenter position between groups.
fn enforceClusters(arena: std.mem.Allocator, total: usize, nranks: usize, members: []std.ArrayList(usize), ec: []const usize, clusters: []const Cluster, role: []const u8) !void {
    const ncl = clusters.len;
    if (ncl == 0) return;

    // Mean position per cluster, credited to every ancestor. An index epsilon
    // keeps distinct clusters from tying (a tie would let their contents mix).
    const sum = try arena.alloc(f64, ncl);
    const cnt = try arena.alloc(f64, ncl);
    @memset(sum, 0);
    @memset(cnt, 0);
    const pos = try arena.alloc(f64, total);
    for (0..nranks) |r| for (members[r].items, 0..) |v, i| {
        pos[v] = @floatFromInt(i);
        if (role[v] != role_none or ec[v] == NO_CLUSTER) continue;
        var c = ec[v];
        while (c != NO_CLUSTER) : (c = clusters[c].parent) {
            sum[c] += pos[v];
            cnt[c] += 1;
        }
    };
    const ckey = try arena.alloc(f64, ncl);
    for (0..ncl) |c| {
        const mean = if (cnt[c] > 0) sum[c] / cnt[c] else 0;
        ckey[c] = mean + @as(f64, @floatFromInt(c)) * 1e-9;
    }

    // Ancestry chain per cluster, root first.
    const chains = try arena.alloc([]usize, ncl);
    for (0..ncl) |c| {
        var depth: usize = 0;
        var k = c;
        while (k != NO_CLUSTER) : (k = clusters[k].parent) depth += 1;
        const buf = try arena.alloc(usize, depth);
        k = c;
        var j = depth;
        while (k != NO_CLUSTER) : (k = clusters[k].parent) {
            j -= 1;
            buf[j] = k;
        }
        chains[c] = buf;
    }

    const ctx = ClusterOrder{ .pos = pos, .ckey = ckey, .ec = ec, .role = role, .chains = chains };
    for (0..nranks) |r| {
        for (members[r].items, 0..) |v, i| pos[v] = @floatFromInt(i);
        std.sort.insertion(usize, members[r].items, ctx, ClusterOrder.less);
    }
}

/// Compares two same-rank nodes by cluster ancestry: level by level the cluster
/// mean positions, then (once a chain is exhausted) the node's own position, or
/// ±inf for that cluster's border dummies, pinning them to the group's extremes.
const ClusterOrder = struct {
    pos: []const f64,
    ckey: []const f64,
    ec: []const usize,
    role: []const u8,
    chains: []const []const usize,

    fn chainOf(self: ClusterOrder, v: usize) []const usize {
        return if (self.ec[v] == NO_CLUSTER) &.{} else self.chains[self.ec[v]];
    }

    fn levelKey(self: ClusterOrder, v: usize, d: usize) f64 {
        const ch = self.chainOf(v);
        if (d < ch.len) return self.ckey[ch[d]];
        return switch (self.role[v]) {
            role_bl => -std.math.inf(f64),
            role_br => std.math.inf(f64),
            else => self.pos[v],
        };
    }

    fn less(self: ClusterOrder, a: usize, b: usize) bool {
        // Prefix-lexicographic: a node whose key sequence is a prefix of the
        // other's sorts first, so a free node tying with a cluster's mean lands
        // beside the whole group, never between its borders.
        const la = self.chainOf(a).len + 1;
        const lb = self.chainOf(b).len + 1;
        var d: usize = 0;
        while (d < @min(la, lb)) : (d += 1) {
            const ka = self.levelKey(a, d);
            const kb = self.levelKey(b, d);
            if (ka < kb) return true;
            if (ka > kb) return false;
        }
        return la < lb;
    }
};

/// Borders go through the canvas line layer, so an edge that legitimately crosses
/// one merges into a junction (tee/cross) and is not overdrawn. Corners and the
/// title stay direct glyphs.
fn drawClusterBox(c: Canvas, ascii: bool, x0: usize, y0: usize, x1: usize, y1: usize, title: []const u8) void {
    const cr = cornerGlyphs(.round, ascii);
    if (title.len > 0 and x0 + 2 < x1) {
        // Break the top run around the title: spaces inside it are empty cells,
        // and a continuous line would show through them.
        const te = @min(x0 + 1 + width.displayWidth(title), x1 - 1);
        c.lineH(x0 + 1, x0 + 2, y0);
        c.lineH(te, x1 - 1, y0);
        c.putStr(x0 + 2, y0, title);
    } else {
        c.lineH(x0 + 1, x1 - 1, y0);
    }
    c.lineH(x0 + 1, x1 - 1, y1);
    c.lineV(y0 + 1, y1 - 1, x0);
    c.lineV(y0 + 1, y1 - 1, x1);
    c.set(x0, y0, cr.tl);
    c.set(x1, y0, cr.tr);
    c.set(x0, y1, cr.bl);
    c.set(x1, y1, cr.br);
    // Faint the border cells (not the interior, so inner nodes stay normal).
    const st = theme.Style{ .faint = true };
    c.fillStyle(x0, y0, x1, y0, st);
    c.fillStyle(x0, y1, x1, y1, st);
    c.fillStyle(x0, y0, x0, y1, st);
    c.fillStyle(x1, y0, x1, y1, st);
}

const KeyCtx = struct { key: []f64 };

fn lessByKey(ctx: KeyCtx, a: usize, b: usize) bool {
    return ctx.key[a] < ctx.key[b];
}

fn median(nbrs: []const usize, pos: []const f64) f64 {
    if (nbrs.len == 0) return -1; // sentinel: keep where stable sort leaves it
    var sum: f64 = 0;
    for (nbrs) |nb| sum += pos[nb];
    return sum / @as(f64, @floatFromInt(nbrs.len)); // barycenter (median's cheaper cousin)
}

// --- Brandes-Köpf cross-axis coordinate assignment ---
//
// "Fast and Simple Horizontal Coordinate Assignment" run on the layered graph
// with virtual nodes. Aligns each edge chain so it draws as a straight line,
// removing the one-column jogs that plain rank-centering produces. `size[i]` is
// a node's cross-axis extent. Adjacent nodes keep a centre distance of
// (size[a]+size[b])/2 + sep. Returns an integer centre coordinate per node,
// normalised so the leftmost (topmost) box edge sits at 0.

fn assignCoords(
    arena: std.mem.Allocator,
    total: usize,
    nranks: usize,
    members: []std.ArrayList(usize),
    up: []std.ArrayList(usize),
    down: []std.ArrayList(usize),
    size: []const usize,
    sep: usize,
    n: usize,
) ![]usize {
    const pos = try arena.alloc(usize, total);
    const rankOf = try arena.alloc(usize, total);
    for (0..nranks) |r| for (members[r].items, 0..) |v, i| {
        pos[v] = i;
        rankOf[v] = r;
    };

    var marked = std.AutoHashMap(u64, void).init(arena);
    try markType1(&marked, total, nranks, members, up, pos, n);

    // Four candidate layouts: down/up vertical alignment × left/right.
    const bk_in: BkInput = .{ .total = total, .nranks = nranks, .members = members, .up = up, .down = down, .marked = &marked, .rankOf = rankOf, .size = size, .sep = sep };
    var cand: [4][]f64 = undefined;
    const dirs = [_][2]bool{ .{ true, true }, .{ true, false }, .{ false, true }, .{ false, false } };
    for (dirs, 0..) |d, ci| {
        cand[ci] = try bkRun(arena, bk_in, d[0], d[1]);
    }
    balance(cand, total);

    // Median of the four, normalised so the smallest box edge is 0.
    const med = try arena.alloc(f64, total);
    var min_edge: f64 = std.math.floatMax(f64);
    for (0..total) |v| {
        var vals = [4]f64{ cand[0][v], cand[1][v], cand[2][v], cand[3][v] };
        std.mem.sort(f64, &vals, {}, std.sort.asc(f64));
        med[v] = (vals[1] + vals[2]) / 2;
        min_edge = @min(min_edge, med[v] - @as(f64, @floatFromInt(size[v])) / 2);
    }
    const out = try arena.alloc(usize, total);
    for (0..total) |v| out[v] = @intFromFloat(@round(med[v] - min_edge));
    return out;
}

fn isMarked(marked: *std.AutoHashMap(u64, void), rankOf: []const usize, total: usize, a: usize, b: usize) bool {
    const key = if (rankOf[a] < rankOf[b]) @as(u64, a) * total + b else @as(u64, b) * total + a;
    return marked.contains(key);
}

/// Flags segments conflicting with an "inner" segment (one between two virtual
/// nodes), per the Brandes-Köpf conflict rule. Keys match isMarked:
/// upperNode * total + lowerNode. Unlike classic BK this scans from the first rank
/// pair: cluster border dummies live on extreme ranks too, so inner segments can
/// start at rank 0.
fn markType1(marked: *std.AutoHashMap(u64, void), total: usize, nranks: usize, members: []std.ArrayList(usize), up: []std.ArrayList(usize), pos: []const usize, n: usize) !void {
    if (nranks < 2) return;
    var i: usize = 0;
    while (i + 1 < nranks) : (i += 1) {
        const lower = members[i + 1].items;
        if (lower.len == 0) continue;
        var k0: usize = 0;
        var l: usize = 0;
        for (lower, 0..) |v, l1| {
            const inner = v >= n and up[v].items.len > 0 and up[v].items[0] >= n;
            if (l1 == lower.len - 1 or inner) {
                var k1: usize = if (members[i].items.len > 0) members[i].items.len - 1 else 0;
                if (inner) k1 = pos[up[v].items[0]];
                while (l <= l1) : (l += 1) {
                    const w = lower[l];
                    for (up[w].items) |u| {
                        const k = pos[u];
                        if (k < k0 or k > k1) try marked.put(@as(u64, u) * total + w, {});
                    }
                }
                k0 = k1;
            }
        }
    }
}

const BkCtx = struct {
    clayers: [][]usize,
    cpos: []usize,
    clayer: []usize,
    root: []usize,
    alignv: []usize,
    sink: []usize,
    shift: []f64,
    x: []f64,
    placed: []bool,
    size: []const usize,
    sep: usize,

    fn placeBlock(self: *BkCtx, v: usize) void {
        if (self.placed[v]) return;
        self.placed[v] = true;
        self.x[v] = 0;
        var w = v;
        while (true) {
            const cl = self.clayer[w];
            const j = self.cpos[w];
            if (j > 0) {
                const left_node = self.clayers[cl][j - 1];
                const u = self.root[left_node];
                self.placeBlock(u);
                if (self.sink[v] == v) self.sink[v] = self.sink[u];
                const delta = @as(f64, @floatFromInt(self.size[left_node] + self.size[w])) / 2 + @as(f64, @floatFromInt(self.sep));
                if (self.sink[v] == self.sink[u]) {
                    self.x[v] = @max(self.x[v], self.x[u] + delta);
                } else {
                    self.shift[self.sink[u]] = @min(self.shift[self.sink[u]], self.x[v] - self.x[u] - delta);
                }
            }
            w = self.alignv[w];
            if (w == v) break;
        }
    }
};

/// The layered graph shared by the four bkRun orientations.
const BkInput = struct {
    total: usize,
    nranks: usize,
    members: []std.ArrayList(usize),
    up: []std.ArrayList(usize),
    down: []std.ArrayList(usize),
    marked: *std.AutoHashMap(u64, void),
    rankOf: []const usize,
    size: []const usize,
    sep: usize,
};

/// One Brandes-Köpf alignment+compaction for a (down, left) orientation, one
/// coordinate per node. Non-canonical orientations come from reversing layer order
/// (down) / within-layer order (left), negating the result for the rightward case.
fn bkRun(arena: std.mem.Allocator, in: BkInput, down_dir: bool, left_dir: bool) ![]f64 {
    const total = in.total;
    const nranks = in.nranks;
    const clayers = try arena.alloc([]usize, nranks);
    for (0..nranks) |cl| {
        const orig = if (down_dir) cl else nranks - 1 - cl;
        const src = in.members[orig].items;
        const buf = try arena.alloc(usize, src.len);
        for (0..src.len) |j| buf[j] = if (left_dir) src[j] else src[src.len - 1 - j];
        clayers[cl] = buf;
    }
    const cpos = try arena.alloc(usize, total);
    const clayer = try arena.alloc(usize, total);
    for (0..nranks) |cl| for (clayers[cl], 0..) |v, j| {
        cpos[v] = j;
        clayer[v] = cl;
    };
    // Canonical predecessors (layer above), sorted by canonical position.
    const pred = try arena.alloc([]usize, total);
    for (0..total) |v| {
        const srcn = if (down_dir) in.up[v].items else in.down[v].items;
        const buf = try arena.dupe(usize, srcn);
        std.sort.insertion(usize, buf, cpos, ltByArr);
        pred[v] = buf;
    }

    const root = try arena.alloc(usize, total);
    const alignv = try arena.alloc(usize, total);
    const sink = try arena.alloc(usize, total);
    const shift = try arena.alloc(f64, total);
    const x = try arena.alloc(f64, total);
    const placed = try arena.alloc(bool, total);
    for (0..total) |v| {
        root[v] = v;
        alignv[v] = v;
        sink[v] = v;
        shift[v] = std.math.inf(f64);
        x[v] = 0;
        placed[v] = false;
    }

    // Vertical alignment.
    var cl: usize = 1;
    while (cl < nranks) : (cl += 1) {
        var rlast: i64 = -1;
        for (clayers[cl]) |v| {
            const P = pred[v];
            const d = P.len;
            if (d == 0) continue;
            const ms = [_]usize{ (d - 1) / 2, d / 2 };
            for (ms) |m| {
                if (alignv[v] != v) break;
                const u = P[m];
                if (!isMarked(in.marked, in.rankOf, total, u, v) and @as(i64, @intCast(cpos[u])) > rlast) {
                    alignv[u] = v;
                    root[v] = root[u];
                    alignv[v] = root[v];
                    rlast = @intCast(cpos[u]);
                }
            }
        }
    }

    // Horizontal compaction.
    var ctx = BkCtx{ .clayers = clayers, .cpos = cpos, .clayer = clayer, .root = root, .alignv = alignv, .sink = sink, .shift = shift, .x = x, .placed = placed, .size = in.size, .sep = in.sep };
    for (0..nranks) |c2| for (clayers[c2]) |v| {
        if (root[v] == v) ctx.placeBlock(v);
    };
    const coord = try arena.alloc(f64, total);
    for (0..total) |v| {
        coord[v] = x[root[v]];
        const s = shift[sink[root[v]]];
        if (s < std.math.inf(f64)) coord[v] += s;
    }
    if (!left_dir) for (0..total) |v| {
        coord[v] = -coord[v];
    };
    return coord;
}

fn ltByArr(key: []const usize, a: usize, b: usize) bool {
    return key[a] < key[b];
}

/// Aligns the four candidates to the narrowest: left ones by their minimum, right
/// ones by their maximum.
fn balance(cand: [4][]f64, total: usize) void {
    if (total == 0) return;
    var mn: [4]f64 = undefined;
    var mx: [4]f64 = undefined;
    for (0..4) |i| {
        var lo: f64 = std.math.inf(f64);
        var hi: f64 = -std.math.inf(f64);
        for (0..total) |v| {
            lo = @min(lo, cand[i][v]);
            hi = @max(hi, cand[i][v]);
        }
        mn[i] = lo;
        mx[i] = hi;
    }
    var best: usize = 0;
    var bestw: f64 = std.math.inf(f64);
    for (0..4) |i| {
        const w = mx[i] - mn[i];
        if (w < bestw) {
            bestw = w;
            best = i;
        }
    }
    for (0..4) |i| {
        const shift = if (i == 0 or i == 2) mn[best] - mn[i] else mx[best] - mx[i];
        for (0..total) |v| cand[i][v] += shift;
    }
}

const Corners = struct { tl: u21, tr: u21, bl: u21, br: u21 };

fn cornerGlyphs(shape: Shape, ascii: bool) Corners {
    if (ascii) return .{ .tl = '+', .tr = '+', .bl = '+', .br = '+' };
    // TODO: subroutine and cylinder fall through to the rect corners below. Neither
    // shape is actually drawn.
    return switch (shape) {
        .round, .stadium, .circle => .{ .tl = '\u{256D}', .tr = '\u{256E}', .bl = '\u{2570}', .br = '\u{256F}' }, // ╭ ╮ ╰ ╯
        .rhombus, .hexagon, .parallelogram => .{ .tl = '/', .tr = '\\', .bl = '\\', .br = '/' },
        else => .{ .tl = '\u{250C}', .tr = '\u{2510}', .bl = '\u{2514}', .br = '\u{2518}' }, // ┌ ┐ └ ┘
    };
}

fn drawBox(c: Canvas, g: Glyphs, x: usize, y: usize, w: usize, shape: Shape, style: theme.Style, ascii: bool, label: []const u8, body: []const []const u8) void {
    const cr = cornerGlyphs(shape, ascii);
    // Top border + centered title.
    c.set(x, y, cr.tl);
    c.hline(x + 1, x + w - 2, y, g.h);
    c.set(x + w - 1, y, cr.tr);
    c.set(x, y + 1, g.v);
    c.set(x + w - 1, y + 1, g.v);
    putCentered(c, x + 1, w - 2, y + 1, label);

    // Member/attribute compartment: a divider, then one left-aligned line each.
    var row = y + 2;
    if (body.len > 0) {
        c.set(x, row, g.te_l);
        c.hline(x + 1, x + w - 2, row, g.h);
        c.set(x + w - 1, row, g.te_r);
        row += 1;
        for (body) |line| {
            c.set(x, row, g.v);
            c.set(x + w - 1, row, g.v);
            c.putStr(x + 2, row, line);
            row += 1;
        }
    }

    // Bottom border (row = y + h - 1).
    c.set(x, row, cr.bl);
    c.hline(x + 1, x + w - 2, row, g.h);
    c.set(x + w - 1, row, cr.br);

    c.fillStyle(x, y, x + w - 1, row, style); // no-op when plain
}

/// Routes a forward edge top-down through its waypoint chain (source box, dummy
/// columns, dest box): a vertical segment per band, a horizontal jog per gap
/// (`jogs[r]` is the routing row after rank r). Adjacent ranks reduce to a stair.
fn routeChainTd(c: Canvas, g: Glyphs, chain: []const usize, bx: []const usize, by: []const usize, bw: []const usize, bh: []const usize, jogs: []const usize, rankT: []const usize, label: []const u8, bidir: bool) void {
    const k = chain.len - 1; // ranks spanned
    const r0 = rankT[chain[0]];

    // Source vertical: from below the source box into the first gap.
    const xs = bx[chain[0]] + bw[chain[0]] / 2;
    c.lineV(by[chain[0]] + bh[chain[0]], jogs[r0], xs);

    // Dummy verticals: span the gap above to the gap below their band.
    var j: usize = 1;
    while (j < chain.len - 1) : (j += 1) {
        const rj = rankT[chain[j]];
        const xj = bx[chain[j]] + bw[chain[j]] / 2;
        c.lineV(jogs[rj - 1], jogs[rj], xj);
    }

    // Destination vertical: from the last gap to just above the dest box.
    const xt = bx[chain[k]] + bw[chain[k]] / 2;
    const rt = rankT[chain[k]];
    const ty = if (by[chain[k]] > 0) by[chain[k]] - 1 else 0;
    c.lineV(jogs[rt - 1], ty, xt);
    c.set(xt, ty, g.a_down);

    // Horizontal jog across each gap.
    var gi: usize = 0;
    while (gi < k) : (gi += 1) {
        const jy = jogs[r0 + gi];
        const xa = bx[chain[gi]] + bw[chain[gi]] / 2;
        const xb = bx[chain[gi + 1]] + bw[chain[gi + 1]] / 2;
        c.lineH(xa, xb, jy);
    }

    // Label above the middle gap's jog (so long edges label near their centre).
    if (label.len > 0) {
        const gm = k / 2;
        const jy = jogs[r0 + gm];
        const xa = bx[chain[gm]] + bw[chain[gm]] / 2;
        const xb = bx[chain[gm + 1]] + bw[chain[gm + 1]] / 2;
        const mid = (xa + xb) / 2;
        const lw = width.displayWidth(label);
        if (jy > 0) c.putStr(if (mid > lw / 2) mid - lw / 2 else 0, jy - 1, label);
    }

    // Source-end arrowhead, after the label so it is never overwritten by it.
    if (bidir) c.set(xs, by[chain[0]] + bh[chain[0]], g.a_up);
}

/// Left-to-right counterpart of routeChainTd (`jogs[r]` is the routing column
/// after column r).
fn routeChainLr(c: Canvas, g: Glyphs, chain: []const usize, bx: []const usize, by: []const usize, bw: []const usize, jogs: []const usize, rankT: []const usize, n: usize, label: []const u8, bidir: bool) void {
    const k = chain.len - 1;
    const r0 = rankT[chain[0]];

    const ys = yAnchor(chain[0], by, n);
    c.lineH(bx[chain[0]] + bw[chain[0]], jogs[r0], ys);

    var j: usize = 1;
    while (j < chain.len - 1) : (j += 1) {
        const rj = rankT[chain[j]];
        const yj = yAnchor(chain[j], by, n);
        c.lineH(jogs[rj - 1], jogs[rj], yj);
    }

    const yt = yAnchor(chain[k], by, n);
    const rt = rankT[chain[k]];
    const tx = if (bx[chain[k]] > 0) bx[chain[k]] - 1 else 0;
    c.lineH(jogs[rt - 1], tx, yt);
    c.set(tx, yt, g.a_right);

    var gi: usize = 0;
    while (gi < k) : (gi += 1) {
        const jx = jogs[r0 + gi];
        const ya = yAnchor(chain[gi], by, n);
        const yb = yAnchor(chain[gi + 1], by, n);
        c.lineV(ya, yb, jx);
    }

    if (label.len > 0) {
        const gm = k / 2;
        const jx = jogs[r0 + gm]; // middle gap, centred in the column gap
        const ya = yAnchor(chain[gm], by, n);
        const lw = width.displayWidth(label);
        if (ya > 0) c.putStr(if (jx > lw / 2) jx - lw / 2 else 0, ya - 1, label);
    }

    // Source-end arrowhead, after the label so it is never overwritten by it.
    if (bidir) c.set(bx[chain[0]] + bw[chain[0]], ys, g.a_left);
}

/// The cross-axis row an LR edge connects to: a real box's title row, or a dummy
/// node's own row.
fn yAnchor(i: usize, by: []const usize, n: usize) usize {
    return if (i < n) by[i] + 1 else by[i];
}

/// Back/same-rank edges take a vertical right-side lane, label in the far-right
/// margin at label_x.
fn routeBackTd(c: Canvas, g: Glyphs, ux: usize, uy: usize, uw: usize, vx: usize, vy: usize, vw: usize, lane: usize, label: []const u8, label_x: usize, bidir: bool) void {
    const ru = ux + uw; // just right of source box
    const rv = vx + vw; // just right of dest box
    const yu = uy + 1;
    const yv = vy + 1;
    c.lineH(ru, lane, yu);
    c.lineV(yu, yv, lane);
    c.lineH(rv, lane, yv);
    c.set(rv, yv, g.a_left); // arrow into dest from the right
    if (bidir) c.set(ru, yu, g.a_left); // back into the source
    if (label.len > 0) c.putStr(label_x, (yu + yv) / 2, label);
}

/// The LR counterpart: a horizontal bottom lane.
fn routeBackLr(c: Canvas, g: Glyphs, ux: usize, uy: usize, uw: usize, uh: usize, vx: usize, vy: usize, vw: usize, vh: usize, lane: usize, label: []const u8, bidir: bool) void {
    const xu = ux + uw / 2;
    const xv = vx + vw / 2;
    const du = uy + uh;
    const dv = vy + vh;
    c.lineV(du, lane, xu);
    c.lineH(xu, xv, lane);
    c.lineV(lane, dv, xv);
    c.set(xv, dv, g.a_up); // arrow into dest from below
    if (bidir) c.set(xu, du, g.a_up); // back into the source
    if (label.len > 0) {
        const xmid = (xu + xv) / 2;
        const lw = width.displayWidth(label);
        c.putStr(if (xmid > lw / 2) xmid - lw / 2 else 0, if (lane > 0) lane - 1 else 0, label);
    }
}

// --- parser: Mermaid flowchart syntax → the layout engine above ---

const ParsedEdge = struct { from: []const u8, to: []const u8, label: []const u8 };

pub fn render(arena: std.mem.Allocator, src: []const u8, ascii: bool, graph_dir: []const u8) ![]const u8 {
    var labels: std.StringHashMap([]const u8) = .init(arena);
    var shapes: std.StringHashMap(Shape) = .init(arena);
    var order: std.ArrayList([]const u8) = .empty; // node ids, first-seen order
    var edges: std.ArrayList(ParsedEdge) = .empty;
    // Styling: classDef name→style, node→class, node→inline style.
    var class_defs: std.StringHashMap(theme.Style) = .init(arena);
    var node_class: std.StringHashMap([]const u8) = .init(arena);
    var style_direct: std.StringHashMap(theme.Style) = .init(arena);
    // Subgraph clusters.
    var clusters: std.ArrayList(Cluster) = .empty;
    var cluster_stack: std.ArrayList(usize) = .empty;
    var node_cluster_map: std.StringHashMap(usize) = .init(arena);
    var dir: Dir = .td;

    var it = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (it.next()) |raw| {
        var t = std.mem.trim(u8, raw, ws);
        if (first) {
            first = false;
            dir = parseDir(t); // direction from the `graph TD` / `flowchart LR` header
            continue;
        }
        if (t.len == 0 or std.mem.startsWith(u8, t, "%%")) continue;
        if (t.len > 0 and t[t.len - 1] == ';') t = std.mem.trim(u8, t[0 .. t.len - 1], ws);
        if (std.mem.startsWith(u8, t, "click ") or std.mem.startsWith(u8, t, "linkStyle")) continue;
        if (std.mem.startsWith(u8, t, "classDef ")) {
            const rest = std.mem.trim(u8, t[9..], ws);
            const sp = std.mem.indexOfAny(u8, rest, " \t") orelse continue;
            try class_defs.put(rest[0..sp], parseStyleDefs(std.mem.trim(u8, rest[sp..], ws)));
            continue;
        }
        if (std.mem.startsWith(u8, t, "class ")) {
            const rest = std.mem.trim(u8, t[6..], ws);
            const sp = std.mem.lastIndexOfAny(u8, rest, " \t") orelse continue;
            const cname = std.mem.trim(u8, rest[sp + 1 ..], ws);
            var nit = std.mem.splitScalar(u8, std.mem.trim(u8, rest[0..sp], ws), ',');
            while (nit.next()) |id0| {
                const id = std.mem.trim(u8, id0, ws);
                if (id.len > 0) try node_class.put(id, cname);
            }
            continue;
        }
        if (std.mem.startsWith(u8, t, "style ")) {
            const rest = std.mem.trim(u8, t[6..], ws);
            const sp = std.mem.indexOfAny(u8, rest, " \t") orelse continue;
            try style_direct.put(rest[0..sp], parseStyleDefs(std.mem.trim(u8, rest[sp..], ws)));
            continue;
        }
        if (std.mem.eql(u8, t, "subgraph") or std.mem.startsWith(u8, t, "subgraph ")) {
            const rest = std.mem.trim(u8, t[8..], ws);
            const parent = if (cluster_stack.items.len > 0) cluster_stack.items[cluster_stack.items.len - 1] else NO_CLUSTER;
            var title = rest;
            if (std.mem.indexOfScalar(u8, rest, '[')) |bi| {
                const be = std.mem.indexOfScalarPos(u8, rest, bi + 1, ']') orelse rest.len;
                title = std.mem.trim(u8, rest[bi + 1 .. be], ws);
            }
            title = std.mem.trim(u8, title, "\"");
            try clusters.append(arena, .{ .title = title, .parent = parent });
            try cluster_stack.append(arena, clusters.items.len - 1);
            continue;
        }
        if (std.mem.eql(u8, t, "end")) {
            if (cluster_stack.items.len > 0) _ = cluster_stack.pop();
            continue;
        }
        const prev_len = order.items.len;
        try parseFlowLine(arena, t, &labels, &shapes, &order, &edges);
        if (cluster_stack.items.len > 0) {
            const cur = cluster_stack.items[cluster_stack.items.len - 1];
            for (order.items[prev_len..]) |id| {
                if (!node_cluster_map.contains(id)) try node_cluster_map.put(id, cur);
            }
        }
    }
    if (order.items.len == 0) return error.Empty;
    if (eqIgnoreCase(graph_dir, "LR")) dir = .lr;
    if (eqIgnoreCase(graph_dir, "TD")) dir = .td;

    // Resolve ids to node indices for the layout engine.
    var index: std.StringHashMap(usize) = .init(arena);
    const nodes = try arena.alloc(Node, order.items.len);
    for (order.items, 0..) |id, i| {
        try index.put(id, i);
        var style: theme.Style = .{};
        if (style_direct.get(id)) |s| {
            style = s;
        } else if (node_class.get(id)) |cn| {
            if (class_defs.get(cn)) |s| style = s;
        }
        nodes[i] = .{ .label = labelOf(labels, id), .shape = shapes.get(id) orelse .rect, .style = style };
    }
    var fedges: std.ArrayList(Edge) = .empty;
    for (edges.items) |e| {
        const fi = index.get(e.from) orelse continue;
        const ti = index.get(e.to) orelse continue;
        try fedges.append(arena, .{ .from = fi, .to = ti, .label = e.label });
    }
    if (clusters.items.len > 0) {
        const node_cluster = try arena.alloc(usize, order.items.len);
        for (order.items, 0..) |id, i| node_cluster[i] = node_cluster_map.get(id) orelse NO_CLUSTER;
        return layoutClustered(arena, nodes, fedges.items, dir, ascii, node_cluster, clusters.items);
    }
    return layout(arena, nodes, fedges.items, dir, ascii);
}

/// `fill:#f9f,stroke:#333,color:#fff` into a Style. The first colour available wins
/// the foreground, in the order fill > stroke > color.
fn parseStyleDefs(defs: []const u8) theme.Style {
    var fill: theme.Color = .none;
    var stroke: theme.Color = .none;
    var color: theme.Color = .none;
    var it = std.mem.splitScalar(u8, defs, ',');
    while (it.next()) |kv0| {
        const kv = std.mem.trim(u8, kv0, ws);
        const ci = std.mem.indexOfScalar(u8, kv, ':') orelse continue;
        const key = std.mem.trim(u8, kv[0..ci], ws);
        const col = parseHexColor(std.mem.trim(u8, kv[ci + 1 ..], ws)) orelse continue;
        if (std.mem.eql(u8, key, "fill")) fill = col else if (std.mem.eql(u8, key, "stroke")) stroke = col else if (std.mem.eql(u8, key, "color")) color = col;
    }
    const fg = if (fill != .none) fill else if (stroke != .none) stroke else color;
    return .{ .fg = fg };
}

fn parseHexColor(s: []const u8) ?theme.Color {
    if (s.len < 4 or s[0] != '#') return null;
    const h = s[1..];
    if (h.len == 3) {
        const r = hexNibble(h[0]) orelse return null;
        const g = hexNibble(h[1]) orelse return null;
        const b = hexNibble(h[2]) orelse return null;
        return .{ .rgb = .{ r * 17, g * 17, b * 17 } };
    }
    if (h.len == 6) {
        const r = hexByte(h[0..2]) orelse return null;
        const g = hexByte(h[2..4]) orelse return null;
        const b = hexByte(h[4..6]) orelse return null;
        return .{ .rgb = .{ r, g, b } };
    }
    return null;
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn hexByte(s: []const u8) ?u8 {
    const hi = hexNibble(s[0]) orelse return null;
    const lo = hexNibble(s[1]) orelse return null;
    return hi * 16 + lo;
}

fn parseDir(header: []const u8) Dir {
    var it = std.mem.tokenizeAny(u8, header, " \t");
    _ = it.next(); // "graph" / "flowchart"
    while (it.next()) |t| {
        if (eqIgnoreCase(t, "LR") or eqIgnoreCase(t, "RL")) return .lr;
        if (eqIgnoreCase(t, "TD") or eqIgnoreCase(t, "TB") or eqIgnoreCase(t, "BT")) return .td;
    }
    return .td;
}

fn labelOf(labels: std.StringHashMap([]const u8), id: []const u8) []const u8 {
    return labels.get(id) orelse id;
}

fn parseFlowLine(
    arena: std.mem.Allocator,
    line: []const u8,
    labels: *std.StringHashMap([]const u8),
    shapes: *std.StringHashMap(Shape),
    order: *std.ArrayList([]const u8),
    edges: *std.ArrayList(ParsedEdge),
) !void {
    var pos: usize = 0;
    var src_node = parseNode(line, &pos) orelse return;
    try recordNode(arena, labels, shapes, order, src_node);
    while (true) {
        skipSpaces(line, &pos);
        if (matchArrow(line, &pos) == null) return; // no further edge on this line
        skipSpaces(line, &pos);
        var elabel: []const u8 = "";
        if (pos < line.len and line[pos] == '|') {
            const close = std.mem.indexOfScalarPos(u8, line, pos + 1, '|') orelse line.len;
            elabel = std.mem.trim(u8, line[pos + 1 .. close], ws);
            pos = if (close < line.len) close + 1 else line.len;
            skipSpaces(line, &pos);
        }
        const dst = parseNode(line, &pos) orelse return;
        try recordNode(arena, labels, shapes, order, dst);
        try edges.append(arena, .{ .from = src_node.id, .to = dst.id, .label = elabel });
        src_node = dst; // support chains: A --> B --> C
    }
}

const ParsedNode = struct { id: []const u8, label: []const u8, shape: Shape = .rect };

fn parseNode(line: []const u8, pos: *usize) ?ParsedNode {
    skipSpaces(line, pos);
    const start = pos.*;
    while (pos.* < line.len and isIdentChar(line[pos.*])) : (pos.* += 1) {}
    const id = line[start..pos.*];
    if (id.len == 0) return null;
    var label: []const u8 = "";
    var shape: Shape = .rect;
    if (pos.* < line.len) {
        const o = line[pos.*];
        const n1: u8 = if (pos.* + 1 < line.len) line[pos.* + 1] else 0;
        var open_len: usize = 1;
        var closeq: []const u8 = "";
        switch (o) {
            '[' => if (n1 == '[') {
                shape = .subroutine;
                closeq = "]]";
                open_len = 2;
            } else if (n1 == '(') {
                shape = .cylinder;
                closeq = ")]";
                open_len = 2;
            } else {
                shape = .rect;
                closeq = "]";
            },
            '(' => if (n1 == '(') {
                shape = .circle;
                closeq = "))";
                open_len = 2;
            } else if (n1 == '[') {
                shape = .stadium;
                closeq = "])";
                open_len = 2;
            } else {
                shape = .round;
                closeq = ")";
            },
            '{' => if (n1 == '{') {
                shape = .hexagon;
                closeq = "}}";
                open_len = 2;
            } else {
                shape = .rhombus;
                closeq = "}";
            },
            '>' => shape = .asymmetric,
            else => closeq = "",
        }
        if (o == '>') closeq = "]";
        if (closeq.len > 0) {
            const istart = pos.* + open_len;
            if (std.mem.indexOf(u8, line[istart..], closeq)) |rel| {
                const cend = istart + rel;
                var inner = std.mem.trim(u8, line[istart..cend], ws);
                // [/text/] [\text\] [/text\] → parallelogram/trapezoid (slanted).
                if (shape == .rect and inner.len > 0 and (inner[0] == '/' or inner[0] == '\\')) {
                    shape = .parallelogram;
                    inner = std.mem.trim(u8, std.mem.trim(u8, inner, "/\\"), ws);
                }
                label = std.mem.trim(u8, inner, "\"");
                pos.* = cend + closeq.len;
            }
        }
    }
    return .{ .id = id, .label = label, .shape = shape };
}

const arrows = [_][]const u8{ "-.->", "==>", "-->", "===", "---", "-.-", "->" };

fn matchArrow(line: []const u8, pos: *usize) ?[]const u8 {
    for (arrows) |op| {
        if (std.mem.startsWith(u8, line[pos.*..], op)) {
            pos.* += op.len;
            return op;
        }
    }
    return null;
}

fn recordNode(
    arena: std.mem.Allocator,
    labels: *std.StringHashMap([]const u8),
    shapes: *std.StringHashMap(Shape),
    order: *std.ArrayList([]const u8),
    node: ParsedNode,
) !void {
    if (node.id.len == 0) return;
    // Dedup on `order` itself: labels only holds bracket-labelled nodes, so a
    // plain id (e.g. `A` in `A-->B` then `B-->C`) would otherwise be re-added.
    var seen = false;
    for (order.items) |id| {
        if (std.mem.eql(u8, id, node.id)) {
            seen = true;
            break;
        }
    }
    if (!seen) try order.append(arena, node.id);
    if (node.label.len > 0) try labels.put(node.id, node.label);
    if (node.shape != .rect) try shapes.put(node.id, node.shape);
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn skipSpaces(line: []const u8, pos: *usize) void {
    while (pos.* < line.len and (line[pos.*] == ' ' or line[pos.*] == '\t')) : (pos.* += 1) {}
}

test "flowchart TD draws boxes and a downward arrow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = [_]Node{ .{ .label = "A" }, .{ .label = "B" } };
    const edges = [_]Edge{.{ .from = 0, .to = 1 }};
    const art = try layout(arena.allocator(), &nodes, &edges, .td, false);
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{250C}") != null); // ┌
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{25BC}") != null); // ▼
}

test "flowchart fan-out forms a tee junction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = [_]Node{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" } };
    const edges = [_]Edge{ .{ .from = 0, .to = 1 }, .{ .from = 0, .to = 2 } };
    const art = try layout(arena.allocator(), &nodes, &edges, .td, false);
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{2534}") != null); // ┴
}

test "flowchart back edge is routed (left arrow appears)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A -> B -> C, plus a back edge C -> A.
    const nodes = [_]Node{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" } };
    const edges = [_]Edge{ .{ .from = 0, .to = 1 }, .{ .from = 1, .to = 2 }, .{ .from = 2, .to = 0 } };
    const art = try layout(arena.allocator(), &nodes, &edges, .td, false);
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{25C0}") != null); // left arrow (back edge) ◀
}

test "flowchart ascii mode uses plain glyphs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = [_]Node{ .{ .label = "X" }, .{ .label = "Y" } };
    const edges = [_]Edge{.{ .from = 0, .to = 1 }};
    const art = try layout(arena.allocator(), &nodes, &edges, .td, true);
    try std.testing.expect(std.mem.indexOf(u8, art, "+") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "v") != null);
}

test "flowchart ordering reduces crossings by reordering a rank" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A->D and B->C with A,B on rank 0 and C,D on rank 1: the crossing is
    // removed by pulling D left (under A), so D's box precedes C's in the output.
    const nodes = [_]Node{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" }, .{ .label = "D" } };
    const edges = [_]Edge{ .{ .from = 0, .to = 3 }, .{ .from = 1, .to = 2 } };
    const art = try layout(arena.allocator(), &nodes, &edges, .td, true);
    const pd = std.mem.indexOf(u8, art, "D").?;
    const pc = std.mem.indexOf(u8, art, "C").?;
    try std.testing.expect(pd < pc);
}

test "flowchart straight chain has aligned box centres (Brandes-Köpf)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = [_]Node{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" } };
    const edges = [_]Edge{ .{ .from = 0, .to = 1 }, .{ .from = 1, .to = 2 } };
    const art = try layout(arena.allocator(), &nodes, &edges, .td, true);
    const ca = colInLine(art, "A");
    const cb = colInLine(art, "B");
    const cc = colInLine(art, "C");
    try std.testing.expectEqual(ca, cb);
    try std.testing.expectEqual(cb, cc);
}

fn colInLine(s: []const u8, needle: []const u8) usize {
    const idx = std.mem.indexOf(u8, s, needle).?;
    const nl = if (std.mem.lastIndexOfScalar(u8, s[0..idx], '\n')) |p| p + 1 else 0;
    return idx - nl;
}

/// Lets the tests do column math on styled art (cluster borders are faint-styled).
fn stripAnsi(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            while (i < s.len and s[i] != 'm') i += 1;
            if (i < s.len) i += 1;
            continue;
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.items;
}

fn rowOf(s: []const u8, needle: []const u8) usize {
    const idx = std.mem.indexOf(u8, s, needle).?;
    return std.mem.count(u8, s[0..idx], "\n");
}

test "cluster: pass-through node is ordered outside the cluster box" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Aaa->Bbb->Ccc with Aaa,Ccc clustered and Bbb free: without border columns
    // the chain would be straightened with Bbb drawn inside the box. The border
    // dummies force it into its own column outside.
    const nodes = [_]Node{ .{ .label = "Aaa" }, .{ .label = "Bbb" }, .{ .label = "Ccc" } };
    const edges = [_]Edge{ .{ .from = 0, .to = 1 }, .{ .from = 1, .to = 2 } };
    const nc = [_]usize{ 0, NO_CLUSTER, 0 };
    const cls = [_]Cluster{.{ .title = "S" }};
    const raw = try layoutClustered(arena.allocator(), &nodes, &edges, .td, true, &nc, &cls);
    const art = try stripAnsi(arena.allocator(), raw);
    try std.testing.expect(colInLine(art, "Bbb") != colInLine(art, "Aaa"));
}

test "cluster: nested cluster box sits inside its parent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // OUTBOX contains Aaa and the INBOX cluster {Bbb}: the inner box's title row
    // and left border must fall strictly inside the outer ones.
    const nodes = [_]Node{ .{ .label = "Aaa" }, .{ .label = "Bbb" } };
    const edges = [_]Edge{.{ .from = 0, .to = 1 }};
    const nc = [_]usize{ 0, 1 };
    const cls = [_]Cluster{ .{ .title = "OUTBOX" }, .{ .title = "INBOX", .parent = 0 } };
    const raw = try layoutClustered(arena.allocator(), &nodes, &edges, .td, true, &nc, &cls);
    const art = try stripAnsi(arena.allocator(), raw);
    try std.testing.expect(rowOf(art, "OUTBOX") < rowOf(art, "INBOX"));
    try std.testing.expect(colInLine(art, "OUTBOX") < colInLine(art, "INBOX"));
}

test "cluster: cross-cluster edge keeps its arrow through the borders" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = [_]Node{ .{ .label = "Aaa" }, .{ .label = "Bbb" } };
    const edges = [_]Edge{.{ .from = 0, .to = 1 }};
    const nc = [_]usize{ 0, 1 };
    const cls = [_]Cluster{ .{ .title = "S1" }, .{ .title = "S2" } };
    const raw = try layoutClustered(arena.allocator(), &nodes, &edges, .td, true, &nc, &cls);
    const art = try stripAnsi(arena.allocator(), raw);
    try std.testing.expect(std.mem.indexOf(u8, art, "v") != null);
}

test "flowchart routes a long edge past intermediate ranks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A->B->C->D plus a long edge A->D spanning three ranks (gets dummy nodes).
    // The intermediate boxes must survive (the long edge routes around them).
    const nodes = [_]Node{ .{ .label = "Aaa" }, .{ .label = "Bbb" }, .{ .label = "Ccc" }, .{ .label = "Ddd" } };
    const edges = [_]Edge{ .{ .from = 0, .to = 1 }, .{ .from = 1, .to = 2 }, .{ .from = 2, .to = 3 }, .{ .from = 0, .to = 3 } };
    const art = try layout(arena.allocator(), &nodes, &edges, .td, false);
    for ([_][]const u8{ "Aaa", "Bbb", "Ccc", "Ddd" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, art, needle) != null);
    }
}

test "parseDir reads the header direction, defaulting to td" {
    try std.testing.expectEqual(Dir.lr, parseDir("graph LR"));
    try std.testing.expectEqual(Dir.td, parseDir("flowchart TB"));
    try std.testing.expectEqual(Dir.td, parseDir("graph"));
}

test "parseHexColor expands #rgb and reads #rrggbb" {
    try std.testing.expectEqual([3]u8{ 255, 153, 255 }, parseHexColor("#f9f").?.rgb);
    try std.testing.expectEqual([3]u8{ 0x33, 0x66, 0x99 }, parseHexColor("#336699").?.rgb);
    try std.testing.expect(parseHexColor("#xyz") == null);
}

test "matchArrow consumes the longest matching arrow" {
    var pos: usize = 0;
    try std.testing.expectEqualStrings("-.->", matchArrow("-.->X", &pos).?);
    try std.testing.expectEqual(@as(usize, 4), pos);
    var p2: usize = 0;
    try std.testing.expect(matchArrow("XY", &p2) == null);
}

test "parseNode reads id, bracket label and shape" {
    var pos: usize = 0;
    const n = parseNode("A[Hello]", &pos).?;
    try std.testing.expectEqualStrings("A", n.id);
    try std.testing.expectEqualStrings("Hello", n.label);
    try std.testing.expectEqual(Shape.rect, n.shape);
    var p2: usize = 0;
    try std.testing.expectEqual(Shape.rhombus, parseNode("B{q}", &p2).?.shape);
    var p3: usize = 0;
    try std.testing.expectEqual(Shape.circle, parseNode("C((o))", &p3).?.shape);
}
