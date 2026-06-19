# Seed Contract

Generated programs must accept one URL argument, fetch JSON todos from that URL,
and print this exact table for the seed data:

```text
USER  COMPLETED  MISSED
3     2          2
2     2          1
4     2          1
5     1          3
1     1          1
7     0          1
6     0          0
```

Use the machine's current local date. A missed deadline is:

```text
completed == false AND dueDate < current local date
```
