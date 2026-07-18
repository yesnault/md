[Syntax Ref]: https://mermaid.ai/open-source/syntax/flowchart.html

# Flowchart node shapes and classDef colours

```mermaid
flowchart TD
A[Rectangle] --> B(Rounded)
A --> C([Stadium])
A --> D[[Subroutine]]
A --> E{Decision}
A --> F{{Hexagon}}
classDef hot fill:#f33,stroke:#900
classDef cool fill:#39f
class E,F hot
style A fill:#3a3
```
