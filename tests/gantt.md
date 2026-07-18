[Syntax Ref]: https://mermaid.ai/open-source/syntax/gantt.html

# Gantt chart

```mermaid
gantt
title A project plan
dateFormat YYYY-MM-DD
section Design
  Spec        :a1, 2014-01-01, 30d
  Review      :after a1, 12d
section Build
  Code        :2014-02-12, 25d
  Ship        :milestone, m1, after a1, 0d
```
