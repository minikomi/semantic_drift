# Semantic Drift Chain Analysis

## Purpose

This document records how the todo-summary program changed while being rewritten
through several language chains. It distinguishes fixture conformance from
behavioral equivalence: every generated stage passed the repository's
conformance oracle, but the oracle exercises only the valid seed fixture. A pass
therefore proves preservation of the required fixture output, not preservation
of all input, error, networking, or edge-case behavior.

The seed behavior is:

1. Accept one todos URL.
2. Fetch a JSON array.
3. Group todos by integer `userId`.
4. Count completed todos.
5. Count incomplete todos whose valid `YYYY-MM-DD` due date is before the
   current local date.
6. Sort by completed descending, missed descending, then user ID ascending.
7. Print the fixed-width table.

## Chains Covered

| Chain | Source lines | Final lines | Final/source | Conformance |
|---|---:|---:|---:|---|
| Go → TypeScript → Python → Ruby → C++ → Java → Haskell → Common Lisp → Zig → Rust → Go | 94 | 443 | 4.7× | Passed at every stage |
| Go → Bash → Go | 94 | 105 | 1.1× | Passed at every stage |
| Go → PHP → Go | 94 | 272 | 2.9× | Passed at every stage |
| Go → Erlang → Go | 94 | 130 | 1.4× | Passed at every stage |

---

## Full Eleven-Stage Chain

### 01 — Original Go

Source: `runs/latest/01-go/project/main.go` (94 lines)

The starting implementation is compact and strongly typed. JSON is decoded
directly into a `[]Todo` containing integer IDs, booleans, and string dates. Go's
HTTP client applies a 10-second total timeout. Incomplete dates are parsed with
`time.ParseInLocation`, so malformed dates fail instead of being compared as
plain strings.

Important baseline behavior outside the fixture:

- Incorrect JSON field types normally fail during decoding.
- Missing struct fields receive Go zero values.
- A missing `dueDate` matters only for an incomplete todo.
- Non-2xx errors include Go's complete status text, such as `404 Not Found`.
- The decoder reads one JSON value and does not explicitly reject all trailing
  content.

### 01 → 02 — Go to TypeScript

Source: `runs/latest/02-typescript/project/src/index.ts` (105 lines)

The main algorithm, timeout, sorting, date validation, and output survive.
Axios replaces Go's HTTP client and `date-fns` replaces Go's date parser.

The first meaningful drift is loss of runtime schema enforcement. `Todo[]` is a
compile-time annotation, not validation of Axios response data. As a result:

- String or complex user IDs can reach a `Map<number, Summary>` at runtime.
- A string such as `"false"` is truthy and can count as completed.
- Missing values become `undefined` rather than Go zero values.
- Numeric subtraction in the tie-break comparator can return `NaN` for invalid IDs.

The fixture remains valid, so conformance still passes.

### 02 → 03 — TypeScript to Python

Source: `runs/latest/03-python/project/src/main.py` (87 lines)

Requests replaces Axios, while Python's standard library replaces `date-fns`.
The valid-data algorithm remains nearly identical.

Behavioral changes occur around dynamic values:

- Missing keys now raise `KeyError` immediately.
- Python dictionaries merge `True`, `1`, and `1.0` as the same key.
- Lists and dictionaries cannot be user IDs because they are unhashable.
- Mixed user-ID types can fail during sorting.
- Empty collections and empty strings are false in Python but not JavaScript.

This stage is shorter and removes a date dependency, but it changes malformed
input semantics.

### 03 → 04 — Python to Ruby

Source: `runs/latest/04-ruby/project/lib/main.rb` (76 lines)

HTTParty replaces Requests; Ruby `Date` and a `Struct` implement the rest. This
is the shortest conventional-language implementation in the full chain.

The main drift is Ruby truthiness:

- Only `false` and `nil` are false.
- `0`, `""`, `[]`, and `{}` are all true and therefore count as completed if
  supplied in the `completed` field.
- Ruby hash semantics keep `true`, `1`, and `1.0` as distinct keys, unlike
  Python.
- Arrays and hashes can be hash keys in Ruby.

Missing fields still fail immediately through `fetch`.

### 04 → 05 — Ruby to C++

Source: `runs/latest/05-cpp/project/src/main.cpp` (286 lines)

This is the first major implementation expansion. libcurl, nlohmann/json,
manual date validation, HTTP header parsing, rendering, and mixed-value sorting
replace Ruby runtime facilities.

Important changes:

- `completed` becomes strict again through `get<bool>()`.
- `dueDate` becomes explicitly string-only.
- `userId` is deliberately generalized to any JSON value.
- Arbitrary user IDs are grouped by serialized JSON.
- Mixed-type user IDs receive deterministic sorting rather than failing.
- Display behavior is defined for strings, numbers, booleans, null, arrays,
  and objects.
- Iterating a top-level JSON object can process its values, accidentally
  accepting object-shaped input.

The generalized JSON user-ID model begins here and survives the remainder of
the full chain. The unused `same_sort_type` helper also appears, indicating
abandoned sorting logic.

### 05 → 06 — C++ to Java

Source: `runs/latest/06-java/project/src/main/java/com/semanticdrift/TodoSummary.java`
(267 lines)

OkHttp and Jackson replace libcurl and nlohmann/json. Most of the C++ structure
is preserved, including generalized JSON IDs and manual date validation.

Jackson introduces coercion:

- `asBoolean()` treats nonzero numbers and trimmed `"true"` as true.
- `asText()` converts numbers and booleans before date parsing.
- Missing fields receive a normalized `key 'field' not found` error.
- Explicit JSON null is still considered present.

Object-valued IDs can group differently because Jackson preserves object field
order while the C++ serializer normally sorts keys. Java also attempts to
reproduce C++ floating-point formatting, but its decimal patterns do not match
C++ stream precision exactly.

### 06 → 07 — Java to Haskell

Source: `runs/latest/07-haskell/project/app/Main.hs` (255 lines)

Aeson and `http-client` replace Jackson and OkHttp. This stage makes several
implicit decisions explicit:

- The top-level value must be a JSON array.
- Every todo eagerly requires `userId`, `completed`, and `dueDate`.
- A completed todo without `dueDate` now fails even though the original Go did
  not need that field.
- Completion is true only for Boolean true, exact string `"true"`, or numeric
  `1`.
- Missing fields and non-object todos use explicit errors.

The exact true/`"true"`/`1` rule and eager field validation survive to the final
Go implementation.

This implementation also has an error-path defect: `run` catches all
exceptions, including the `exitFailure` raised by its own `failWith`, so some
failures can print both the intended message and `ExitFailure 1`.

### 07 → 08 — Haskell to Common Lisp

Source: `runs/latest/08-common-lisp/project/src/main.lisp` (231 lines)

Dexador and Yason replace the Haskell libraries. Core JSON, aggregation,
sorting, date, and coercion semantics remain stable.

Notable changes:

- A dedicated `app-error` condition fixes Haskell's duplicate-error behavior.
- HTTP failures are normalized and checked centrally.
- A fixed table of HTTP reason phrases is introduced.
- The timeout changes from one response timeout to separate 10-second connect
  and read timeouts.
- Counts become arbitrary-size Lisp integers.
- `value-rank` is introduced but never used.
- Usage output can mistakenly use the first supplied argument as the program
  name when multiple arguments are given.

The hard-coded HTTP reason table survives all remaining stages.

### 08 → 09 — Common Lisp to Zig

Source: `runs/latest/09-zig/project/src/main.zig` (361 lines)

The Zig standard library and C time functions replace Dexador, Yason, and Lisp
date support. The implementation expands to handle allocation, formatting,
direct file-descriptor output, error variants, and JSON values explicitly.

Important changes:

- The HTTP timeout disappears entirely.
- Usage text hard-codes `todo-summary`.
- Counts become signed 64-bit integers and can overflow.
- Date parsing becomes ASCII-only and platform-dependent through `mktime`.
- Numeric and JSON serialization behavior changes again.

Zig also introduces two use-after-free-style error-message defects:

- A bad date stores a slice into a temporary buffer that is freed before the
  outer handler prints it.
- A bad HTTP status stores an allocated reason phrase that is freed before the
  outer handler uses it.

Valid fixture execution does not exercise either defect. The missing timeout
does survive into Rust and final Go.

### 09 → 10 — Zig to Rust

Source: `runs/latest/10-rust/project/src/main.rs` (315 lines)

Reqwest, Serde JSON, and libc replace the Zig facilities. This is largely a
cleanup translation.

- Owned `String` errors and static reason phrases fix both Zig lifetime bugs.
- No HTTP timeout is restored.
- Strict arrays, eager fields, hard-coded usage, and the reason table remain.
- Serde adds unsigned 64-bit number representation.
- Large numeric IDs can lose precision when comparison falls back to `f64`.
- Out-of-range integral float rendering saturates through Rust casts rather
  than trapping as Zig may.
- Date handling remains based on C `mktime`.

### 10 → 11 — Rust to Final Go

Source: `runs/latest/11-go/project/main.go` (443 lines)

The final translation removes external dependencies but expands significantly.
Rust enums and pattern matching become explicit Go error kinds, switches,
manual JSON-number handling, formatting helpers, and comparison functions.

Retained accumulated behavior:

- No HTTP timeout.
- Generalized JSON user IDs.
- Grouping by serialized JSON.
- Strict top-level array.
- Eager requirement of all three fields.
- Completion coercion for true, `"true"`, and numeric `1`.
- Fixed HTTP reason table.
- Hard-coded usage text.

New or changed details:

- `json.Decoder.UseNumber` preserves original number spelling.
- `1`, `1.0`, and `1e0` can become distinct grouping keys even when all render
  as `1`.
- Non-`int64` numeric sorting still falls back to `float64` and can lose
  precision.
- Output write errors are ignored.
- `cloneJSONValue` is a no-op translation artifact.
- Date handling returns from C `mktime` to Go `time.Date`.

The final program is fixture-correct but behaviorally much broader and more
complex than the original.

---

## Go → Bash → Go

### 01 — Original Go

Source: `runs/go-bash-go/01-go/project/main.go` (94 lines)

This is an exact copy of `runs/latest/01-go/project`.

### 01 → 02 — Go to Bash

Source: `runs/go-bash-go/02-bash/project/run.sh` (55 lines)

The Bash implementation uses curl, jq, a temporary response file, and the
system `date` command.

Preserved behavior:

- 10-second request timeout.
- Non-2xx rejection.
- Grouping, counts, sorting, and table formatting for the fixture.

Drift:

- Dates are compared lexically as strings instead of parsed.
- jq truthiness accepts more `completed` values than Go.
- IDs are converted through jq `tostring` for grouping.
- Non-2xx errors lose the reason phrase and report only the status code.
- The header is printed before jq processing, so malformed JSON can leave
  partial stdout.

### 02 → 03 — Bash to Final Go

Source: `runs/go-bash-go/03-go/project/main.go` (105 lines)

The final Go code returns to integer IDs and Boolean completion, but preserves
the Bash string-date comparison:

```go
} else if item.DueDate < today {
    summary.Missed++
}
```

Consequences:

- Valid ISO dates still work.
- Invalid or missing dates no longer produce the original Go parse error.
- A missing date may compare as overdue.
- Status errors still omit the reason phrase.
- JSON decoding is now `json.Unmarshal`, which is stricter about trailing
  content than the original decoder.

This is the smallest final implementation and has the least structural growth,
but date validation is a meaningful loss.

---

## Go → PHP → Go

### 01 — Original Go

Source: `runs/go-php-go/01-go/project/main.go` (94 lines)

This is an exact copy of the original Go project.

### 01 → 02 — Go to PHP

Source: `runs/go-php-go/02-php/project/src/main.php` (107 lines)

Guzzle provides HTTP and Composer records dependencies. The implementation
retains a 10-second timeout, date parsing, local-midnight comparison, sorting,
and output formatting.

The primary drift is explicit PHP casting:

- `userId` is cast with `(int)`.
- `completed` is cast with `(bool)`.
- `dueDate` is cast with `(string)`.
- Missing or non-array todo entries are converted into zero/empty defaults.
- PHP's associative-array model means top-level JSON objects also satisfy
  `is_array` and may be processed.

The wrapper runs `composer install` on every invocation; its conditional has
identical branches.

### 02 → 03 — PHP to Final Go

Source: `runs/go-php-go/03-go/project/main.go` (272 lines)

The final Go implementation explicitly emulates PHP rather than returning to
the original Go schema. It adds helpers for:

- PHP integer conversion, including numeric string prefixes.
- PHP Boolean truthiness.
- PHP string conversion.
- PHP associative-array iteration.
- PHP-flavored date errors.

This produces nearly three times the original source size. It preserves date
parsing and a 10-second timeout, but carries PHP's coercive data model into Go.
The complexity is mostly semantic emulation, not the core todo algorithm.

---

## Go → Erlang → Go

### 01 — Original Go

Source: `runs/go-erlang-go/01-go/project/main.go` (94 lines)

This is an exact copy of the original Go project.

### 01 → 02 — Go to Erlang

Source: `runs/go-erlang-go/02-erlang/project/src/todo_summary.erl` (127 lines)

The Erlang implementation uses a rebar3 escript, Hackney for HTTP, and JSX for
JSON.

Preserved behavior:

- Integer IDs and exact Boolean values.
- Parsed and validated dates.
- Local-date comparison.
- Grouping and sort priorities.
- Fixed-width output.

Differences:

- Connect and receive each have a 10-second timeout rather than one total
  request timeout.
- Missing keys fail through `maps:get`.
- Invalid dates use Erlang tuple-style error text.
- The sorting predicate uses `=<` for equal IDs, which is not a strict ordering
  predicate, though duplicate IDs are grouped before sorting.
- Hackney and JSX add external dependencies.

### 02 → 03 — Erlang to Final Go

Source: `runs/go-erlang-go/03-go/project/main.go` (130 lines)

The final Go implementation remains close to the original algorithm and keeps
date parsing and a 10-second timeout. It introduces Resty despite Go's standard
HTTP client already being sufficient.

Notable drift:

- Erlang-style bad-date strings are retained.
- The sort comparator uses `<=` instead of `<`, copied from Erlang's `=<`.
  `sort.Slice` requires a strict less function, so this is formally invalid for
  equal elements even though grouped user IDs make equal tie-break IDs unlikely.
- Resty and two indirect modules add dependencies.
- The original unused `id` field disappears harmlessly.

This result is substantially cleaner than the PHP round trip and preserves
date validation unlike the Bash round trip.

---

## Comparative Findings

### Conformance Was Necessary but Too Narrow

Every stage passed because every stage produced the correct output for the same
valid fixture. The oracle did not detect:

- Runtime schema coercion.
- Missing-field policy changes.
- Acceptance of top-level objects.
- Invalid-date behavior.
- HTTP timeout loss.
- Error-message lifetime bugs.
- Numeric precision and serialization changes.
- Invalid sort predicates.

Additional adversarial fixtures would be required to make those behaviors part
of conformance.

### Dynamic-Language Semantics Tend to Survive the Return to Go

The final translator often preserves the immediate source's runtime semantics
instead of recovering the original Go model:

- Bash contributes lexical date comparison.
- PHP contributes extensive casting emulation.
- Erlang contributes tuple-style errors and a non-strict comparator.
- The full chain accumulates generalized JSON values, coercion, eager fields,
  and fixed reason phrases.

### More Stages Produce More Semantic Surface Area

The full chain does not merely rewrite the original algorithm. It accumulates
new policies for generic JSON display, grouping, comparison, coercion, error
normalization, and HTTP behavior. Those policies account for most of the growth
from 94 to 443 lines.

### Round-Trip Quality Ranking

For this experiment, judged by fidelity to the original implementation rather
than fixture output alone:

1. **Erlang round trip:** retains parsed dates and timeout behavior with modest
   growth, but adds Resty and an invalid non-strict comparator.
2. **Bash round trip:** smallest and simplest final result, but loses date
   validation and status reason phrases.
3. **PHP round trip:** retains dates and timeout, but imports PHP coercion into
   178 additional lines of Go.
4. **Full chain:** largest semantic and structural drift, including timeout
   loss, generic JSON IDs, coercion, eager fields, and extensive helper logic.

The ranking could change if simplicity is weighted more heavily than malformed
input fidelity; under that criterion, the Bash result is the most attractive.

## Recommended Conformance Expansion

To measure semantic preservation rather than fixture reproduction, add cases
for:

1. Missing `userId`, `completed`, and `dueDate` independently.
2. Completed todos without a due date.
3. Wrong types for every field.
4. `completed` values of `0`, `1`, `"true"`, `"false"`, empty collections, and
   non-empty collections.
5. String, Boolean, null, array, and object user IDs.
6. Large integers, floats, exponent notation, and IDs beyond exact `float64`
   range.
7. Invalid dates, leap days, and dates equal to today.
8. Top-level null, object, scalar, and malformed JSON.
9. Trailing JSON content.
10. Non-2xx responses with and without reason phrases.
11. Slow connect, slow headers, and slow response body behavior.
12. Broken stdout and early client disconnects.

These cases would turn many currently invisible implementation choices into
measured compatibility requirements.
