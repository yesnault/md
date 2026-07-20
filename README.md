# md

A terminal Markdown reader, written in Zig. It renders Markdown to styled
ANSI: headings, lists, tables, code blocks with syntax highlighting, and
Mermaid diagrams as text art.
Output goes to a scrollable full-screen pager, or straight to stdout when piped.

`md` is also consumable as a library (see [example](example/README.md)): depend on the package and import the `md`
module (`renderToAnsi`, `theme`, `ansiseg`).

![md demo](demo.gif)

## Requirements

- **Zig 0.16** to build.
- A Unix-like OS (Linux, macOS). Windows is not supported.

## Build

```sh
make build         # zig build --release=safe
make install       # install to $HOME/.local/bin/md (override with PREFIX=...)
make test          # run the test suite
```


## Usage

```sh
md README.md            # open in the scrollable pager
md --no-tui README.md   # render once to stdout (ANSI), e.g. piped to a pager
cat README.md | md      # read Markdown from stdin
md - < README.md        # same, explicit stdin
```

### Options

```
-w, --width <n>           word-wrap width (0 = terminal width, capped at 120)
-s, --style <name>        theme: dark | light | notty (no color) (default: dark)
    --no-tui              force rendering to stdout (no TUI)
    --tui                 force the interactive TUI
    --ascii               render diagrams with ASCII instead of Unicode
    --graph-dir <LR|TD>   flowchart direction hint
    --image               render Mermaid diagrams as images
    --image-protocol <p>  auto|kitty|sixel|halfblocks|none (implies --image)
    --goto-line <n>       TUI: open at the section containing source line n
    --find <text>         TUI: open at the first line containing <text>,
                          highlighted, ready for n/N (smartcase)
                          (with --goto-line: search starts at that section)
-h, --help                show help
```

`md` shows the pager when stdout is a terminal. When output is piped (or with
`--no-tui`) it prints ANSI and exits.

### Pager keys

```
↑/↓ or j/k         scroll one line
PgUp/PgDn          scroll one page  (Space = page down)
g / G              jump to top / bottom
Tab / Shift+Tab    select the next / previous link
Enter              follow the selected link
                   (#anchor jumps in-doc, .md opens the file,
                    URLs open externally)
Backspace          go back to the previous document
/                  search: matches highlight as you type
                   (Enter keeps them, Esc cancels and goes back)
n / N              jump to the next / previous match
q / Esc / Ctrl+C   quit
```

Search is smartcase: an all-lowercase pattern matches any case, a pattern with
an uppercase letter matches exactly.

## Mermaid diagram support

Runnable examples for every supported type live in [`tests/`](tests/).

## Picking files with fzf

`md` has no file browser on purpose. Compose it with `fzf`:

```sh
md "$(fzf)"                                    # fuzzy-pick a file, then view it
fd -e md | fzf | xargs md                      # restrict to .md files
md "$(fzf --preview 'md --no-tui {} | head -200')"   # live Markdown preview

# handy alias / function
alias mdf='md "$(fzf)"'
mdf() { local f; f=$(fd -e md -e markdown | fzf --preview 'md --no-tui {} | head -300') && md "$f"; }
```

## License

[MIT](LICENSE). See individual files in `vendor/` for vendored dependency licenses.
