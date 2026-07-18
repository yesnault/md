//! Mermaid diagram rendering to terminal text art.
//!
//! Blocks are intercepted directly in the Markdown renderer (no sentinels), then
//! dispatched by first token to a dedicated renderer or to the shared 2D
//! box-drawing engine (flowchart.zig).
//!
//! Every per-type `render` keeps the same contract: arena-allocated art with no
//! trailing newline, or an error when the source holds nothing to draw. Only
//! OutOfMemory escapes dispatch. Every semantic error means "show the source".

const std = @import("std");
const fc = @import("flowchart.zig");
const seq = @import("sequence.zig");
const gantt = @import("gantt.zig");
const mindmap = @import("mindmap.zig");
const timeline = @import("timeline.zig");
const quadrant = @import("quadrant.zig");
const kanban = @import("kanban.zig");
const gitgraph = @import("gitgraph.zig");
const treemap = @import("treemap.zig");
const zenuml = @import("zenuml.zig");
const architecture = @import("architecture.zig");
const c4 = @import("c4.zig");
const packet = @import("packet.zig");
const xychart = @import("xychart.zig");
const sankey = @import("sankey.zig");
const radar = @import("radar.zig");
const block = @import("block.zig");
const pie = @import("pie.zig");
const journey = @import("journey.zig");
const state = @import("state.zig");
const class = @import("class.zig");
const requirement = @import("requirement.zig");
const text = @import("text.zig");

pub const Options = struct {
    ascii: bool = false,
    /// "", "LR" or "TD" (advisory, the compact layout is direction-agnostic).
    graph_dir: []const u8 = "",
};

const ws = text.ws;

/// Null when the diagram type is unsupported, or when its source does not parse.
pub fn render(arena: std.mem.Allocator, src: []const u8, opts: Options) error{OutOfMemory}!?[]const u8 {
    return dispatch(arena, src, opts) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

fn dispatch(arena: std.mem.Allocator, src: []const u8, opts: Options) !?[]const u8 {
    const tok = firstMeaningfulToken(src);
    if (eqIgnoreCase(tok, "pie")) return try pie.render(arena, src, opts.ascii);
    if (eqIgnoreCase(tok, "sequencediagram")) return try seq.render(arena, src, opts.ascii);
    if (eqIgnoreCase(tok, "graph") or eqIgnoreCase(tok, "flowchart") or eqIgnoreCase(tok, "flowchart-elk")) return try fc.render(arena, src, opts.ascii, opts.graph_dir);
    if (eqIgnoreCase(tok, "statediagram") or eqIgnoreCase(tok, "statediagram-v2")) return try state.render(arena, src, opts.ascii, opts.graph_dir);
    if (eqIgnoreCase(tok, "classdiagram")) return try class.render(arena, src, opts.ascii, opts.graph_dir, .td);
    if (eqIgnoreCase(tok, "erdiagram")) return try class.render(arena, src, opts.ascii, opts.graph_dir, .lr);
    if (eqIgnoreCase(tok, "gantt")) return try gantt.render(arena, src, opts.ascii);
    if (eqIgnoreCase(tok, "mindmap")) return try mindmap.render(arena, src, opts.ascii);
    if (eqIgnoreCase(tok, "journey")) return try journey.render(arena, src, opts.ascii);
    if (eqIgnoreCase(tok, "timeline")) return try timeline.render(arena, src, opts.ascii);
    if (eqIgnoreCase(tok, "requirementdiagram")) return try requirement.render(arena, src, opts.ascii, opts.graph_dir);
    if (eqIgnoreCase(tok, "quadrantchart")) return try quadrant.render(arena, src, opts.ascii);
    if (eqIgnoreCase(tok, "kanban")) return try kanban.render(arena, src, opts.ascii);
    if (eqIgnoreCase(tok, "gitgraph") or eqIgnoreCase(tok, "gitgraph:")) return try gitgraph.render(arena, src, opts.ascii);
    if (eqIgnoreCase(tok, "treemap") or eqIgnoreCase(tok, "treemap-beta")) return try treemap.render(arena, src, opts.ascii);
    if (eqIgnoreCase(tok, "zenuml")) return try zenuml.render(arena, src, opts.ascii);
    if (eqIgnoreCase(tok, "architecture") or eqIgnoreCase(tok, "architecture-beta")) return try architecture.render(arena, src, opts.ascii);
    if (eqIgnoreCase(tok, "c4context") or eqIgnoreCase(tok, "c4container") or eqIgnoreCase(tok, "c4component") or eqIgnoreCase(tok, "c4dynamic") or eqIgnoreCase(tok, "c4deployment")) return try c4.render(arena, src, opts.ascii);
    if (eqIgnoreCase(tok, "packet") or eqIgnoreCase(tok, "packet-beta")) return try packet.render(arena, src, opts.ascii);
    if (eqIgnoreCase(tok, "xychart") or eqIgnoreCase(tok, "xychart-beta")) return try xychart.render(arena, src, opts.ascii);
    if (eqIgnoreCase(tok, "sankey") or eqIgnoreCase(tok, "sankey-beta")) return try sankey.render(arena, src, opts.ascii);
    if (eqIgnoreCase(tok, "radar") or eqIgnoreCase(tok, "radar-beta")) return try radar.render(arena, src, opts.ascii);
    if (eqIgnoreCase(tok, "block") or eqIgnoreCase(tok, "block-beta")) return try block.render(arena, src, opts.ascii);
    return null;
}

pub fn typeName(src: []const u8) []const u8 {
    const t = firstMeaningfulToken(src);
    return if (t.len == 0) "empty" else t;
}

// --- shared helpers ---

fn firstMeaningfulToken(src: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, ws);
        if (t.len == 0) continue;
        if (std.mem.eql(u8, t, "---")) {
            // skip YAML frontmatter
            while (it.next()) |f| {
                if (std.mem.eql(u8, std.mem.trim(u8, f, ws), "---")) break;
            }
            continue;
        }
        if (std.mem.startsWith(u8, t, "%%")) continue;
        const sp = std.mem.indexOfAny(u8, t, " \t") orelse return t;
        return t[0..sp];
    }
    return "";
}

const eqIgnoreCase = text.eqIgnoreCase;

test "pie renders bars and percentages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "pie title Pets\n\"Cats\" : 60\n\"Dogs\" : 40\n";
    const art = (try render(arena.allocator(), src, .{ .ascii = true })).?;
    try std.testing.expect(std.mem.indexOf(u8, art, "Pets") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "Cats") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "60.0%") != null);
}

test "flowchart TD renders boxes with resolved labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "graph TD\nA[Start] --> B{Choice}\nB --> C[End]\n";
    const art = (try render(arena.allocator(), src, .{ .ascii = true })).?;
    try std.testing.expect(std.mem.indexOf(u8, art, "Start") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "Choice") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "End") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "v") != null); // ascii down arrow
}

test "flowchart supports chained edges and edge labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "flowchart LR\nA -->|yes| B --> C\n";
    const art = (try render(arena.allocator(), src, .{ .ascii = true })).?;
    for ([_][]const u8{ "A", "B", "C", "yes", ">" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, art, needle) != null);
    }
}

test "flowchart node shapes and classDef colours" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "flowchart TD\n" ++
        "A(Round) --> B{Dec}\n" ++
        "classDef hot fill:#f00\n" ++
        "class B hot\n";
    const art = (try render(arena.allocator(), src, .{})).?;
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{256D}") != null); // rounded corner ╭
    try std.testing.expect(std.mem.indexOf(u8, art, "\x1b[38;2;255;0;0m") != null); // classDef red
}

test "flowchart subgraph groups nodes in a titled cluster box" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "flowchart TD\n" ++
        "Start --> A\n" ++
        "subgraph one [Group One]\n" ++
        "A --> B\n" ++
        "B --> C\n" ++
        "end\n" ++
        "C --> Done\n";
    const art = (try render(arena.allocator(), src, .{ .ascii = true })).?;
    for ([_][]const u8{ "Group One", "Start", "A", "B", "C", "Done" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, art, needle) != null);
    }
}

test "flowchart ascii shapes fall back to plain corners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const art = (try render(arena.allocator(), "flowchart TD\nA(Round) --> B[Rect]\n", .{ .ascii = true })).?;
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{256D}") == null); // no rounded glyph in ascii ╭
    try std.testing.expect(std.mem.indexOf(u8, art, "+") != null);
}

test "sequence renders participant boxes, aliases and message text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "sequenceDiagram\nparticipant A as Alice\nA->>Bob: Hello\n";
    const art = (try render(arena.allocator(), src, .{ .ascii = true })).?;
    for ([_][]const u8{ "Alice", "Bob", "Hello", ">" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, art, needle) != null);
    }
}

test "sequence parses fragments, notes and activation suffixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "sequenceDiagram\n" ++
        "A->>+B: req\n" ++
        "loop retry\n" ++
        "B->>B: work\n" ++
        "end\n" ++
        "note over A,B: done\n" ++
        "B-->>-A: resp\n";
    const art = (try render(arena.allocator(), src, .{})).?;
    try std.testing.expect(std.mem.indexOf(u8, art, "retry") != null); // frame label
    try std.testing.expect(std.mem.indexOf(u8, art, "done") != null); // note
    try std.testing.expect(std.mem.indexOf(u8, art, "resp") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{2503}") != null); // activation bar ┃
}

test "stateDiagram renders states and [*] pseudo-states" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "stateDiagram-v2\n[*] --> Idle\nIdle --> Running : start\nRunning --> [*]\n";
    const art = (try render(arena.allocator(), src, .{ .ascii = true })).?;
    try std.testing.expect(std.mem.indexOf(u8, art, "Idle") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "Running") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "(*)") != null); // pseudo-state dot (ascii)
    try std.testing.expect(std.mem.indexOf(u8, art, "v") != null); // a down arrow
}

test "classDiagram renders classes, relationships and member bodies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "classDiagram\n" ++
        "class Animal {\n" ++
        "  +String name\n" ++
        "  +eat()\n" ++
        "}\n" ++
        "Animal <|-- Dog\n" ++
        "Dog : +bark()\n";
    const art = (try render(arena.allocator(), src, .{ .ascii = true })).?;
    for ([_][]const u8{ "Animal", "Dog", "+String name", "+eat()", "+bark()" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, art, needle) != null);
    }
}

test "erDiagram renders entities, relations and attribute bodies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "erDiagram\n" ++
        "CUSTOMER ||--o{ ORDER : places\n" ++
        "CUSTOMER {\n" ++
        "  string name\n" ++
        "  int id PK\n" ++
        "}\n";
    const art = (try render(arena.allocator(), src, .{ .ascii = true })).?;
    for ([_][]const u8{ "CUSTOMER", "ORDER", "places", "string name", "int id PK" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, art, needle) != null);
    }
}

test "journey renders sections, scores and actors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "journey\ntitle My day\nsection Work\nMake tea: 5: Me\nDo work: 1: Me, Cat\n";
    const art = (try render(arena.allocator(), src, .{ .ascii = true })).?;
    try std.testing.expect(std.mem.indexOf(u8, art, "My day") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "Work") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "Make tea") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "(5)") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "Cat") != null);
}

test "gantt and mindmap are now rendered (not source fallback)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try render(arena.allocator(), "gantt\ntitle X\nsection S\nt :2014-01-01, 3d\n", .{ .ascii = true })) != null);
    try std.testing.expect((try render(arena.allocator(), "mindmap\n  root\n    leaf\n", .{ .ascii = true })) != null);
}

test "timeline is rendered (not source fallback)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try render(arena.allocator(), "timeline\ntitle X\n2002 : LinkedIn\n", .{ .ascii = true })) != null);
}

test "requirementDiagram renders requirement/element boxes and relations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "requirementDiagram\n" ++
        "requirement test_req {\n" ++
        "  id: 1\n" ++
        "  text: the test text.\n" ++
        "  risk: high\n" ++
        "}\n" ++
        "element test_entity {\n" ++
        "  type: simulation\n" ++
        "}\n" ++
        "test_entity - satisfies -> test_req\n";
    const art = (try render(arena.allocator(), src, .{ .ascii = true })).?;
    for ([_][]const u8{ "test_req", "test_entity", "<<requirement>>", "<<element>>", "the test text.", "satisfies" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, art, needle) != null);
    }
}

test "quadrantChart, kanban and gitGraph are rendered (not source fallback)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try render(arena.allocator(), "quadrantChart\nA: [0.3, 0.6]\n", .{ .ascii = true })) != null);
    try std.testing.expect((try render(arena.allocator(), "kanban\n  Todo\n    [Card]\n", .{ .ascii = true })) != null);
    try std.testing.expect((try render(arena.allocator(), "gitGraph\ncommit\nbranch dev\ncommit\n", .{ .ascii = true })) != null);
}

test "treemap is rendered (not source fallback)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try render(arena.allocator(), "treemap-beta\n\"S1\"\n  \"A\": 3\n  \"B\": 1\n", .{ .ascii = true })) != null);
    try std.testing.expect((try render(arena.allocator(), "treemap\nRoot\n  A: 2\n", .{ .ascii = true })) != null);
}

test "zenuml is rendered (not source fallback)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try render(arena.allocator(), "zenuml\nAlice->Bob: Hi\n", .{ .ascii = true })) != null);
    try std.testing.expect((try render(arena.allocator(), "zenuml\n@Starter(A)\nB.run()\n", .{ .ascii = true })) != null);
}

test "architecture is rendered (not source fallback)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try render(arena.allocator(), "architecture-beta\nservice a(server)[A]\nservice b(server)[B]\na:R -- L:b\n", .{ .ascii = true })) != null);
    try std.testing.expect((try render(arena.allocator(), "architecture\nservice a[A]\n", .{ .ascii = true })) != null);
}

test "C4 diagrams are rendered (not source fallback)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect((try render(a, "C4Context\nPerson(p,\"P\")\nSystem(s,\"S\")\nRel(p,s,\"uses\")\n", .{ .ascii = true })) != null);
    try std.testing.expect((try render(a, "C4Container\nContainer(c,\"C\",\"Java\")\n", .{ .ascii = true })) != null);
    try std.testing.expect((try render(a, "C4Component\nComponent(c,\"C\")\n", .{ .ascii = true })) != null);
    try std.testing.expect((try render(a, "C4Dynamic\nContainer(a,\"A\")\nContainer(b,\"B\")\nRel(a,b,\"x\")\n", .{ .ascii = true })) != null);
    try std.testing.expect((try render(a, "C4Deployment\nDeployment_Node(n,\"N\"){\nContainer(c,\"C\")\n}\n", .{ .ascii = true })) != null);
}

test "packet and xychart are rendered (not source fallback)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect((try render(a, "packet-beta\n0-15: \"Src\"\n16-31: \"Dst\"\n", .{ .ascii = true })) != null);
    try std.testing.expect((try render(a, "packet\n0: \"Flag\"\n", .{ .ascii = true })) != null);
    try std.testing.expect((try render(a, "xychart-beta\nx-axis [a, b]\nbar [1, 2]\n", .{ .ascii = true })) != null);
    try std.testing.expect((try render(a, "xychart\nline [3, 1, 2]\n", .{ .ascii = true })) != null);
}

test "sankey and radar are rendered (not source fallback)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect((try render(a, "sankey-beta\nA,B,10\nA,C,5\n", .{ .ascii = true })) != null);
    try std.testing.expect((try render(a, "sankey\nX,Y,1\n", .{ .ascii = true })) != null);
    try std.testing.expect((try render(a, "radar-beta\naxis a[\"A\"], b[\"B\"], c[\"C\"]\ncurve s[\"S\"]{1, 2, 3}\n", .{ .ascii = true })) != null);
    try std.testing.expect((try render(a, "radar\naxis a, b, c\ncurve s{3, 2, 1}\n", .{ .ascii = true })) != null);
}

test "block is rendered (not source fallback)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect((try render(a, "block-beta\ncolumns 3\na b c\n", .{ .ascii = true })) != null);
    try std.testing.expect((try render(a, "block\ncolumns 2\nx[\"X\"] y[\"Y\"]\nx --> y\n", .{ .ascii = true })) != null);
}

test "unsupported diagram returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try render(arena.allocator(), "quadrantChart\ntitle X\n", .{})) == null);
}

test "stateDiagram composite states render as titled clusters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "stateDiagram-v2\n" ++
        "[*] --> Setup\n" ++
        "state \"Working phase\" as Work {\n" ++
        "  [*] --> Fetch\n" ++
        "  Fetch --> Store\n" ++
        "}\n" ++
        "Setup --> Work\n" ++
        "Work --> [*]\n";
    const art = (try render(arena.allocator(), src, .{ .ascii = true })).?;
    // Cluster title, members, and the scoped start dot all render.
    try std.testing.expect(std.mem.indexOf(u8, art, "Working phase") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "Fetch") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "Store") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "(*)") != null);
    // The edge into the composite exists: no "Work" box is drawn (retargeted).
    try std.testing.expect(std.mem.indexOf(u8, art, "\u{2502} Work \u{2502}") == null); // │ Work │
}

test "flowchart-elk dispatches to the flowchart renderer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const art = (try render(arena.allocator(), "flowchart-elk LR\nA --> B\n", .{ .ascii = true })).?;
    try std.testing.expect(std.mem.indexOf(u8, art, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, ">") != null); // LR arrow
}

test "render distinguishes out-of-memory from unsupported" {
    // A failing allocator must surface OutOfMemory, not degrade to the
    // source fallback the way semantic parse errors do.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, render(failing.allocator(), "pie\n\"A\": 1\n", .{}));

    // A parseable header with no content is a semantic error: null fallback.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try render(arena.allocator(), "gantt\n", .{})) == null);
}

test "firstMeaningfulToken skips frontmatter and %% comments" {
    try std.testing.expectEqualStrings("gitGraph", firstMeaningfulToken("gitGraph\ncommit\n"));
    try std.testing.expectEqualStrings("flowchart", firstMeaningfulToken("---\ntitle: x\n---\nflowchart TD\n"));
    try std.testing.expectEqualStrings("sequenceDiagram", firstMeaningfulToken("%% c\nsequenceDiagram\n"));
}
