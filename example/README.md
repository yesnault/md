# md as a library — example

A minimal, standalone Zig package that depends on `md` and renders a Markdown
string to styled ANSI, printed to stdout.

## Run

```sh
cd example
zig build run
```

## How it depends on md

`build.zig.zon` declares md as a path dependency to the sibling checkout:

```zig
.dependencies = .{
    .md = .{ .path = ".." },
},
```

A consumer outside this repo would instead point at a released archive and let
`zig fetch` pin the hash:

```sh
zig fetch --save git+https://github.com/yesnault/md
```

```zig
.dependencies = .{
    .md = .{
        .url = "git+https://github.com/yesnault/md#<commit>",
        .hash = "...",
    },
},
```

```zig
const md_dep = b.dependency("md", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("md", md_dep.module("md"));
```

md wires its own `vaxis` import and C dependencies (md4c, tree-sitter) into that
module, so there is nothing else to add.

## md.renderToAnsi

```zig
const md = @import("md");

const ansi = try md.renderToAnsi(gpa, document, .{ .width = 72, .style = "dark" });
```

`renderToAnsi(gpa, markdown, opts) ![]u8` returns an owned slice of ANSI text.
Handy options in `md.Options` (see [`../src/options.zig`](../src/options.zig)):

- `width` — wrap width; `0` detects the terminal (capped at 120).
- `style` — `"dark"` | `"light"` | `"notty"` (no color); `""` picks dark.
- `ascii` — draw diagrams with ASCII instead of Unicode box-drawing.

See [`main.zig`](main.zig) for the full program.
