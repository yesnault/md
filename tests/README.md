# Mermaid render examples

One Markdown file per supported diagram type, for eyeballing the renderer.

```sh
# render one (Unicode)
zig build run -- --no-tui tests/flowchart.md

# or after `make install`
md --no-tui tests/gantt.md
md --no-tui --ascii tests/class.md     # plain ASCII instead of box-drawing
```

| File | Type |
|------|------|
| [pie.md](pie.md) | `pie` |
| [flowchart.md](flowchart.md) | `flowchart` / `graph` |
| [shapes.md](shapes.md) | `flowchart` node shapes + classDef colours |
| [subgraph.md](subgraph.md) | `flowchart` subgraphs |
| [sequence.md](sequence.md) | `sequenceDiagram` (loop/alt, notes, activation) |
| [state.md](state.md) | `stateDiagram-v2` |
| [class.md](class.md) | `classDiagram` |
| [er.md](er.md) | `erDiagram` |
| [gantt.md](gantt.md) | `gantt` |
| [mindmap.md](mindmap.md) | `mindmap` |
| [journey.md](journey.md) | `journey` |
| [timeline.md](timeline.md) | `timeline` |
| [requirement.md](requirement.md) | `requirementDiagram` |
| [quadrant.md](quadrant.md) | `quadrantChart` |
| [kanban.md](kanban.md) | `kanban` |
| [gitgraph.md](gitgraph.md) | `gitGraph` |
| [treemap.md](treemap.md) | `treemap` / `treemap-beta` |
| [zenuml.md](zenuml.md) | `zenuml` |
| [architecture.md](architecture.md) | `architecture` / `architecture-beta` |
| [c4context.md](c4context.md) | `C4Context` |
| [c4container.md](c4container.md) | `C4Container` |
| [c4component.md](c4component.md) | `C4Component` |
| [c4dynamic.md](c4dynamic.md) | `C4Dynamic` |
| [c4deployment.md](c4deployment.md) | `C4Deployment` |
| [packet.md](packet.md) | `packet` / `packet-beta` |
| [xychart.md](xychart.md) | `xychart` / `xychart-beta` |
| [sankey.md](sankey.md) | `sankey` / `sankey-beta` |
| [radar.md](radar.md) | `radar` / `radar-beta` |
| [block.md](block.md) | `block` / `block-beta` |
