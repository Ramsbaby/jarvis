---
title: "ADR"
tags: [area/knowledge, type/moc]
created: 2026-03-06
updated: 2026-03-06
---

# Architecture Decision Records

```dataview
TABLE WITHOUT ID
  file.link AS "ADR",
  dateformat(file.mtime, "MM-dd") AS "수정일"
FROM "06-knowledge/adr"
WHERE file.name != "_index"
SORT file.name ASC
```

---
연결: [[06-knowledge/_index|지식]] | [[Home]]
