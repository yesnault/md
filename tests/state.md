[Syntax Ref]: https://mermaid.ai/open-source/syntax/stateDiagram.html

# State diagram

```mermaid
stateDiagram-v2
[*] --> Idle
Idle --> Running : start
Running --> Idle : stop
Running --> [*]
```

Composite states draw as titled boxes; edges on a composite attach to its
scoped `[*]` start/end (or first member), and composites nest.

```mermaid
stateDiagram-v2
[*] --> Setup
state "Working phase" as Work {
  [*] --> Fetch
  Fetch --> Store
  state Store {
    [*] --> Write
  }
}
Setup --> Work
Work --> [*]
```
