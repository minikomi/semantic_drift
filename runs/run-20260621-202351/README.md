# Translation Chain Run

This directory contains one complete behavior-preserving translation chain:

```text
Go → TypeScript → Python → Ruby → C++ → Java
   → Haskell → Common Lisp → Zig → Rust → Go
```

Each numbered directory is the output of a fresh Codex process translating only
the immediately preceding project. Translators ran in separate temporary
workspaces and were not shown the repository name, historical runs, archive
path, or experiment terminology.

This run used the second prompt condition, `prompts/rewrite-neutral.md`, selected
as `--prompt-variant neutral`. Unlike the original `prompts/rewrite.md`, it omits
the instruction to prefer mainstream ecosystem libraries. The C++ stage then
implemented JSON parsing manually; that implementation strategy was inherited by
the remaining translations.

Every generated project passed the same output verification using the supplied
todos endpoint. The verifier checks one valid fixture, so a pass establishes
matching output for that fixture rather than full semantic equivalence for every
possible input or failure mode.

The original Go implementation is 94 lines. After ten translations, the final
Go implementation is 969 lines. See `01-go/project` for the starting point and
`11-go/project` for the result.

The run began on 2026-06-21 and completed on 2026-06-22 (Asia/Tokyo).
