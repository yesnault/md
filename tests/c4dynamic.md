[Syntax Ref]: https://mermaid.ai/open-source/syntax/c4.html

# C4 Dynamic diagram

```mermaid
C4Dynamic
title Dynamic diagram for Internet Banking System - API Application
Container(spa, "Single-Page App", "JavaScript, Angular")
Container(api, "API Application", "Java, Spring MVC")
ContainerDb(database, "Database", "SQL Database")
Rel(spa, api, "Submits credentials to")
Rel(api, database, "Validates credentials with")
```
