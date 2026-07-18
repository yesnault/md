[Syntax Ref]: https://mermaid.ai/open-source/syntax/c4.html

# C4 Component diagram

```mermaid
C4Component
title Component diagram for Internet Banking System - API Application
Container_Boundary(api, "API Application") {
  Component(sign, "Sign In Controller", "Spring MVC Rest Controller", "Allows users to sign in.")
  Component(accounts, "Accounts Summary Controller", "Spring MVC Rest Controller", "Provides account balances.")
  Component(security, "Security Component", "Spring Bean", "Provides functionality related to signing in.")
  Component(mbsfacade, "Mainframe Banking System Facade", "Spring Bean", "A facade onto the mainframe banking system.")
}
ContainerDb(database, "Database", "SQL Database", "Stores user registration information.")
System_Ext(mbs, "Mainframe Banking System", "Stores core banking information.")
Rel(sign, security, "Uses")
Rel(accounts, mbsfacade, "Uses")
Rel(security, database, "Reads from and writes to", "JDBC")
Rel(mbsfacade, mbs, "Uses", "XML/HTTPS")
```
