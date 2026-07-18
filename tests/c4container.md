[Syntax Ref]: https://mermaid.ai/open-source/syntax/c4.html

# C4 Container diagram

```mermaid
C4Container
title Container diagram for Internet Banking System
Person(customer, "Banking Customer", "A customer of the bank.")
System_Boundary(c1, "Internet Banking") {
  Container(web_app, "Web Application", "Java, Spring MVC", "Delivers the static content and the Internet banking SPA.")
  Container(spa, "Single-Page App", "JavaScript, Angular", "Provides Internet banking functionality via the browser.")
  ContainerDb(database, "Database", "SQL Database", "Stores user registration information, hashed credentials, access logs, etc.")
}
System_Ext(email_system, "E-Mail System", "The internal Microsoft Exchange system.")
Rel(customer, web_app, "Uses", "HTTPS")
Rel(customer, spa, "Uses", "HTTPS")
Rel(spa, database, "Reads from and writes to", "JDBC")
Rel(web_app, email_system, "Sends e-mail using", "SMTP")
```
