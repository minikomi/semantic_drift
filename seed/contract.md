# Seed Contract

Generated programs must accept one URL argument, fetch JSON todos from that URL,
and print this exact table for the seed data:

```text
USER  COMPLETED  MISSED
2     2          1
1     1          1
```

Use `2026-06-16` as the fixed reference date. A missed deadline is:

```text
completed == false AND dueDate < 2026-06-16
```
