[Syntax Ref]: https://mermaid.ai/open-source/syntax/flowchart.html

# Flowchart

A decision flow with a branch, a join, and a back edge.

```mermaid
graph TD
A[Start] --> B{Choice}
B -->|yes| C[Do it]
B -->|no| D[Skip]
C --> E[End]
D --> E
E --> B
```

Left-to-right with a long edge that skips a rank.

```mermaid
flowchart LR
A --> B
B --> C
A -->|skip| C
```

The `flowchart-elk` header is an alias (the ELK layout hint is ignored).

```mermaid
flowchart-elk LR
A[In] --> B[Out]
```
