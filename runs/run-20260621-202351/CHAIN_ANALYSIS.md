# Programming-language translation chain analysis

Chain: `01-go -> 02-typescript -> 03-python -> 04-ruby -> 05-cpp -> 06-java -> 07-haskell -> 08-common-lisp -> 09-zig -> 10-rust -> 11-go`

## Executive summary

The single checked behavior is stable: fetch a URL, parse a todo list, count completed and missed todos by user, sort by completed descending, missed descending, then user id ascending, and print the fixed table header. The original Go implementation expresses that directly with typed structs, standard HTTP, standard JSON, standard date parsing, and standard sorting ([01-go/project/main.go:12](01-go/project/main.go:12), [01-go/project/main.go:31](01-go/project/main.go:31), [01-go/project/main.go:44](01-go/project/main.go:44), [01-go/project/main.go:64](01-go/project/main.go:64), [01-go/project/main.go:79](01-go/project/main.go:79), [01-go/project/main.go:90](01-go/project/main.go:90)).

The final Go implementation is not a return to the original design. It is a 969-line reimplementation with a custom JSON value model and parser, Python-like truthiness, Java-like string comparison and padding, shell-outs to `curl` for HTTP, and shell-out to `date` for today's date ([11-go/project/main.go:14](11-go/project/main.go:14), [11-go/project/main.go:358](11-go/project/main.go:358), [11-go/project/main.go:554](11-go/project/main.go:554), [11-go/project/main.go:696](11-go/project/main.go:696), [11-go/project/main.go:862](11-go/project/main.go:862), [11-go/project/main.go:885](11-go/project/main.go:885)).

The most important cumulative drifts are:

- Typed decoding became permissive, dynamic JSON processing. Original Go rejects many malformed or wrongly typed fields during `json.Decoder.Decode` into `[]Todo` ([01-go/project/main.go:44](01-go/project/main.go:44)); by 11-go, any top-level non-array silently produces only the header because processing is guarded by `if todos.kind == arrayKind` ([11-go/project/main.go:899](11-go/project/main.go:899)).
- `completed` changed from a strict boolean to Python-like truthiness. Missing `completed` ultimately counts as completed because `undefinedKind` is truthy ([11-go/project/main.go:554](11-go/project/main.go:554), [11-go/project/main.go:903](11-go/project/main.go:903)).
- `userId` changed from a required Go `int` to an arbitrary JSON value, grouped by JSON stringification and rendered with Python-style display ([11-go/project/main.go:662](11-go/project/main.go:662), [11-go/project/main.go:928](11-go/project/main.go:928)).
- HTTP changed from in-process clients to external `curl` starting in Haskell, and this external dependency was preserved through the final Go ([07-haskell/project/app/Main.hs:419](07-haskell/project/app/Main.hs:419), [11-go/project/main.go:862](11-go/project/main.go:862)).
- Today's date changed from host-language local date APIs to an external `date +%Y-%m-%d` command starting in Zig and preserved through Rust and Go ([09-zig/project/src/main.zig:645](09-zig/project/src/main.zig:645), [11-go/project/main.go:885](11-go/project/main.go:885)).
- Unicode/string behavior drifted repeatedly. Java introduced UTF-16 ordering and padding semantics ([06-java/project/src/TodoReport.java:620](06-java/project/src/TodoReport.java:620), [06-java/project/src/TodoReport.java:632](06-java/project/src/TodoReport.java:632)); later versions explicitly emulate that for sorting/padding ([07-haskell/project/app/Main.hs:407](07-haskell/project/app/Main.hs:407), [11-go/project/main.go:696](11-go/project/main.go:696), [11-go/project/main.go:780](11-go/project/main.go:780)). Rust briefly changed raw non-escaped JSON string byte handling by pushing each byte as a Unicode scalar ([10-rust/project/src/main.rs:172](10-rust/project/src/main.rs:172)); final Go changed that again by writing raw bytes ([11-go/project/main.go:206](11-go/project/main.go:206)).

The README's verifier caveat is borne out by the code: passing one fixture proves matching output for that fixture, not semantic equivalence across malformed JSON, field type variation, redirects, encodings, timeouts, boundary dates, Unicode, or runtime environments ([README.md:15](README.md:15)).

## Implementation-size measurements

Principal source files, measured with `wc -l`:

| Stage | Principal source | Lines |
|---:|---|---:|
| 01 | [01-go/project/main.go](01-go/project/main.go) | 94 |
| 02 | [02-typescript/project/src/main.ts](02-typescript/project/src/main.ts) | 126 |
| 03 | [03-python/project/todo_report.py](03-python/project/todo_report.py) | 129 |
| 04 | [04-ruby/project/todo_report.rb](04-ruby/project/todo_report.rb) | 174 |
| 05 | [05-cpp/project/main.cpp](05-cpp/project/main.cpp) | 775 |
| 06 | [06-java/project/src/TodoReport.java](06-java/project/src/TodoReport.java) | 738 |
| 07 | [07-haskell/project/app/Main.hs](07-haskell/project/app/Main.hs) | 540 |
| 08 | [08-common-lisp/project/main.lisp](08-common-lisp/project/main.lisp) | 501 |
| 09 | [09-zig/project/src/main.zig](09-zig/project/src/main.zig) | 731 |
| 10 | [10-rust/project/src/main.rs](10-rust/project/src/main.rs) | 838 |
| 11 | [11-go/project/main.go](11-go/project/main.go) | 969 |

The source size increases by about 10.3x from 01-go to 11-go, mostly because library JSON/HTTP/date behavior was translated into local compatibility code and then carried forward.

## Drift timeline

| First stage | Behavior change | Later trajectory |
|---|---|---|
| 02-typescript | Typed Go structs become unchecked dynamic values after `response.json()`; `completed`, `userId`, and `dueDate` can now be non-Go-shaped at runtime ([02-typescript/project/src/main.ts:74](02-typescript/project/src/main.ts:74), [02-typescript/project/src/main.ts:92](02-typescript/project/src/main.ts:92)). | General dynamic handling is preserved and expanded through 11-go. |
| 02-typescript | Request timeout no longer covers body JSON parsing because the abort timer is cleared immediately after `fetch` resolves, before `response.json()` ([02-typescript/project/src/main.ts:56](02-typescript/project/src/main.ts:56), [02-typescript/project/src/main.ts:64](02-typescript/project/src/main.ts:64), [02-typescript/project/src/main.ts:76](02-typescript/project/src/main.ts:76)). | Later stages use per-client/read timeouts or `curl --max-time 10`; behavior changes again. |
| 03-python | Missing `completed` becomes truthy via a custom `_UNDEFINED` sentinel, so missing completion counts as completed rather than attempting due-date parsing ([03-python/project/todo_report.py:41](03-python/project/todo_report.py:41), [03-python/project/todo_report.py:107](03-python/project/todo_report.py:107)). | Preserved explicitly as Python-like truthiness through 11-go ([11-go/project/main.go:554](11-go/project/main.go:554)). |
| 03-python | Empty arrays/objects in `completed` become false under Python truthiness, unlike JavaScript where arrays/objects are truthy ([03-python/project/todo_report.py:107](03-python/project/todo_report.py:107)). | Preserved by explicit truthiness functions in Ruby and later ([04-ruby/project/todo_report.rb:66](04-ruby/project/todo_report.rb:66), [11-go/project/main.go:554](11-go/project/main.go:554)). |
| 04-ruby | Mixed-type user-id sorting becomes totalized by `py_key` rather than Python's possible `TypeError` for incomparable key types ([03-python/project/todo_report.py:118](03-python/project/todo_report.py:118), [04-ruby/project/todo_report.rb:115](04-ruby/project/todo_report.rb:115)). | Preserved and elaborated through Java-style string comparison. |
| 05-cpp | Standard JSON parsing becomes a custom parser; numbers become doubles and object lookup/grouping is by canonical JSON stringification ([05-cpp/project/main.cpp:66](05-cpp/project/main.cpp:66), [05-cpp/project/main.cpp:252](05-cpp/project/main.cpp:252), [05-cpp/project/main.cpp:588](05-cpp/project/main.cpp:588)). | Custom parsers persist through 11-go. |
| 05-cpp | Top-level non-array input changes to header-only output because processing is guarded by `if (todos.type == Array)` ([05-cpp/project/main.cpp:722](05-cpp/project/main.cpp:722)). | Preserved through 11-go ([11-go/project/main.go:901](11-go/project/main.go:901)). |
| 06-java | String sort/padding semantics become Java UTF-16 semantics ([06-java/project/src/TodoReport.java:620](06-java/project/src/TodoReport.java:620), [06-java/project/src/TodoReport.java:632](06-java/project/src/TodoReport.java:632)). | Later stages intentionally emulate Java string comparison/length ([07-haskell/project/app/Main.hs:407](07-haskell/project/app/Main.hs:407), [11-go/project/main.go:696](11-go/project/main.go:696)). |
| 07-haskell | HTTP becomes an external `curl --include --max-time 10 --connect-timeout 10` subprocess, with hand-parsed status/body ([07-haskell/project/app/Main.hs:419](07-haskell/project/app/Main.hs:419), [07-haskell/project/app/Main.hs:440](07-haskell/project/app/Main.hs:440)). | Preserved through Common Lisp, Zig, Rust, and final Go ([11-go/project/main.go:862](11-go/project/main.go:862)). |
| 08-common-lisp | Date acquisition moves earlier relative to fetch: Haskell fetches before getting today; Lisp passes `today-universal-day` before `fetch-json` in the main call form ([07-haskell/project/app/Main.hs:531](07-haskell/project/app/Main.hs:531), [08-common-lisp/project/main.lisp:493](08-common-lisp/project/main.lisp:493)). | Zig/Rust/Go keep computing today before fetching ([11-go/project/main.go:944](11-go/project/main.go:944)). |
| 09-zig | Today's date becomes an external `date +%Y-%m-%d` subprocess ([09-zig/project/src/main.zig:645](09-zig/project/src/main.zig:645)). | Preserved in Rust and final Go ([10-rust/project/src/main.rs:752](10-rust/project/src/main.rs:752), [11-go/project/main.go:885](11-go/project/main.go:885)). |
| 10-rust | Raw non-escaped JSON string bytes are converted byte-by-byte into Rust chars ([10-rust/project/src/main.rs:172](10-rust/project/src/main.rs:172)). | 11-go alters this by writing raw bytes instead ([11-go/project/main.go:206](11-go/project/main.go:206)). |

## Adjacent comparisons

### 01-go -> 02-typescript

Strategy change: a small typed Go CLI using `http.Client`, `encoding/json`, and `time.ParseInLocation` becomes an async Node/TypeScript CLI using global `fetch`, unchecked type assertions, and a hand-written Go-date parser ([01-go/project/main.go:31](01-go/project/main.go:31), [01-go/project/main.go:44](01-go/project/main.go:44), [02-typescript/project/src/main.ts:56](02-typescript/project/src/main.ts:56), [02-typescript/project/src/main.ts:74](02-typescript/project/src/main.ts:74)).

Preserved behavior: one URL argument; stderr usage/error with exit 1 from the program; reject non-2xx; count completed todos; parse only incomplete due dates; compare due dates against local today at midnight; sort by completed descending, missed descending, user id ascending; same table shape ([01-go/project/main.go:26](01-go/project/main.go:26), [01-go/project/main.go:39](01-go/project/main.go:39), [01-go/project/main.go:61](01-go/project/main.go:61), [01-go/project/main.go:79](01-go/project/main.go:79), [02-typescript/project/src/main.ts:51](02-typescript/project/src/main.ts:51), [02-typescript/project/src/main.ts:68](02-typescript/project/src/main.ts:68), [02-typescript/project/src/main.ts:92](02-typescript/project/src/main.ts:92), [02-typescript/project/src/main.ts:108](02-typescript/project/src/main.ts:108)).

Definite drift:

- Input coercion: Go decodes into `int`, `bool`, and `string` fields ([01-go/project/main.go:12](01-go/project/main.go:12)); TypeScript asserts `Todo[]` but does not validate runtime JSON ([02-typescript/project/src/main.ts:74](02-typescript/project/src/main.ts:74)). Non-boolean `completed` is handled by JavaScript truthiness at runtime ([02-typescript/project/src/main.ts:92](02-typescript/project/src/main.ts:92)); Go would reject incompatible JSON during decode.
- Date coercion: TypeScript's regex/date parser receives runtime values from JSON and JavaScript APIs coerce non-strings before matching; Go's `DueDate string` requires JSON string decoding before `time.ParseInLocation` runs ([01-go/project/main.go:16](01-go/project/main.go:16), [01-go/project/main.go:64](01-go/project/main.go:64), [02-typescript/project/src/main.ts:28](02-typescript/project/src/main.ts:28), [02-typescript/project/src/main.ts:97](02-typescript/project/src/main.ts:97)).
- HTTP timeout: Go's client timeout is on the client used for the whole request ([01-go/project/main.go:31](01-go/project/main.go:31)). TypeScript clears the abort timer immediately after `fetch` resolves and before `response.json()` reads the body ([02-typescript/project/src/main.ts:56](02-typescript/project/src/main.ts:56), [02-typescript/project/src/main.ts:64](02-typescript/project/src/main.ts:64), [02-typescript/project/src/main.ts:76](02-typescript/project/src/main.ts:76)).
- JSON trailing data: Go decodes one JSON value from the stream and does not check for EOF after `Decode` ([01-go/project/main.go:45](01-go/project/main.go:45)); `response.json()` parses the whole response as JSON ([02-typescript/project/src/main.ts:76](02-typescript/project/src/main.ts:76)).
- Build/runtime: Go runs `go run .` directly ([01-go/project/run.sh:10](01-go/project/run.sh:10)); TypeScript installs dependencies if absent, compiles, then starts Node ([02-typescript/project/run.sh:11](02-typescript/project/run.sh:11), [02-typescript/project/run.sh:15](02-typescript/project/run.sh:15)).

Uncertain/equivalent: both default HTTP stacks follow redirects, but their exact redirect limits and status text normalization are implementation-dependent. The date intent is equivalent for valid `YYYY-MM-DD` inputs.

### 02-typescript -> 03-python

Strategy change: async Node/fetch becomes synchronous Python using `urllib.request`, `json.loads`, and `datetime.date`; custom helpers are added to mimic some JavaScript stringification while using Python data structures ([02-typescript/project/src/main.ts:50](02-typescript/project/src/main.ts:50), [03-python/project/todo_report.py:23](03-python/project/todo_report.py:23), [03-python/project/todo_report.py:69](03-python/project/todo_report.py:69)).

Preserved behavior: one argument; 2xx check; 10-second network timeout parameter; local date comparison; table layout; sort priorities for normal numeric user ids ([02-typescript/project/src/main.ts:51](02-typescript/project/src/main.ts:51), [02-typescript/project/src/main.ts:68](02-typescript/project/src/main.ts:68), [03-python/project/todo_report.py:72](03-python/project/todo_report.py:72), [03-python/project/todo_report.py:98](03-python/project/todo_report.py:98), [03-python/project/todo_report.py:117](03-python/project/todo_report.py:117)).

Definite drift:

- Truthiness: JavaScript treats arrays and objects as truthy, and missing `completed` is falsey. Python uses `todo.get(..., _UNDEFINED)`; the sentinel is truthy, while empty lists/dicts are falsey ([02-typescript/project/src/main.ts:92](02-typescript/project/src/main.ts:92), [03-python/project/todo_report.py:41](03-python/project/todo_report.py:41), [03-python/project/todo_report.py:107](03-python/project/todo_report.py:107)).
- Sorting: TypeScript subtracts user ids, which coerces numeric-looking values and yields `NaN` for many non-numeric values ([02-typescript/project/src/main.ts:115](02-typescript/project/src/main.ts:115)). Python sorts by a tuple containing `item["userId"]`, which raises for many mixed incomparable types ([03-python/project/todo_report.py:118](03-python/project/todo_report.py:118)).
- Grouping: TypeScript `Map` can key by object identity ([02-typescript/project/src/main.ts:84](02-typescript/project/src/main.ts:84)); Python dict keys require hashable user ids, so list/dict user ids fail ([03-python/project/todo_report.py:99](03-python/project/todo_report.py:99)).
- Output formatting for non-normal user ids differs: TypeScript uses JavaScript `String(...)` ([02-typescript/project/src/main.ts:120](02-typescript/project/src/main.ts:120)); Python uses `str(...)` ([03-python/project/todo_report.py:122](03-python/project/todo_report.py:122)).
- HTTP timeout semantics differ: TypeScript's timer no longer covers body parsing after `fetch`; Python passes `timeout=10` to `urlopen`, a socket timeout rather than the same abort-controller behavior ([02-typescript/project/src/main.ts:64](02-typescript/project/src/main.ts:64), [03-python/project/todo_report.py:72](03-python/project/todo_report.py:72)).

Uncertain/equivalent: for valid fixture-shaped JSON, JSON parsing and date comparisons are equivalent. Exact redirect handling is library-defined in both environments.

### 03-python -> 04-ruby

Strategy change: Python stdlib HTTP/JSON/date becomes Ruby stdlib `Net::HTTP`, `JSON`, and `Date`, with explicit emulation of Python truthiness, `str`, and `repr` behavior ([03-python/project/todo_report.py:69](03-python/project/todo_report.py:69), [04-ruby/project/todo_report.rb:37](04-ruby/project/todo_report.rb:37), [04-ruby/project/todo_report.rb:66](04-ruby/project/todo_report.rb:66), [04-ruby/project/todo_report.rb:100](04-ruby/project/todo_report.rb:100)).

Preserved behavior: missing fields use an `UNDEFINED` sentinel; Python-like truthiness is used; invalid date shape/range gives similar messages; normal grouping/counting/sorting/output are preserved ([03-python/project/todo_report.py:45](03-python/project/todo_report.py:45), [03-python/project/todo_report.py:48](03-python/project/todo_report.py:48), [03-python/project/todo_report.py:101](03-python/project/todo_report.py:101), [04-ruby/project/todo_report.rb:10](04-ruby/project/todo_report.rb:10), [04-ruby/project/todo_report.rb:79](04-ruby/project/todo_report.rb:79), [04-ruby/project/todo_report.rb:146](04-ruby/project/todo_report.rb:146)).

Definite drift:

- Sorting mixed user ids: Python may raise when tuple comparison reaches incomparable raw user ids ([03-python/project/todo_report.py:118](03-python/project/todo_report.py:118)). Ruby introduces `py_key`, grouping nil/bool/number/string/other into a total order ([04-ruby/project/todo_report.rb:115](04-ruby/project/todo_report.rb:115), [04-ruby/project/todo_report.rb:164](04-ruby/project/todo_report.rb:164)).
- HTTP redirects: Python `urlopen` normally uses urllib handlers, including redirects; Ruby's `Net::HTTP.start(...).get` performs a single request and does not follow redirects by itself ([03-python/project/todo_report.py:72](03-python/project/todo_report.py:72), [04-ruby/project/todo_report.rb:102](04-ruby/project/todo_report.rb:102)).
- Timeout shape: Python passes one `timeout=10` to `urlopen` ([03-python/project/todo_report.py:72](03-python/project/todo_report.py:72)); Ruby sets separate `open_timeout: 10` and `read_timeout: 10` ([04-ruby/project/todo_report.rb:102](04-ruby/project/todo_report.rb:102)).
- Error text for library failures changes from Python exception strings to Ruby exception strings because each uses `str(err)`/`err.to_s` ([03-python/project/todo_report.py:18](03-python/project/todo_report.py:18), [04-ruby/project/todo_report.rb:17](04-ruby/project/todo_report.rb:17)).

Uncertain/equivalent: JSON duplicate-key handling appears intended to be last-value-wins in both library parsers, but exact insertion-order behavior for duplicates is library-specific. For normal fixture data, behavior is equivalent.

### 04-ruby -> 05-cpp

Strategy change: a Ruby script using stdlib JSON/HTTP/date becomes a C++17 program with a custom JSON value type/parser, manual Python/JS formatting helpers, libcurl HTTP, and manual date arithmetic ([04-ruby/project/todo_report.rb:100](04-ruby/project/todo_report.rb:100), [05-cpp/project/main.cpp:18](05-cpp/project/main.cpp:18), [05-cpp/project/main.cpp:66](05-cpp/project/main.cpp:66), [05-cpp/project/main.cpp:540](05-cpp/project/main.cpp:540), [05-cpp/project/main.cpp:665](05-cpp/project/main.cpp:665)).

Preserved behavior: Python-like truthiness; date shape/range checks including year 0000-0099 rejection; no redirect following; 10-second connect/overall timeout; normal table rendering and sort priorities ([04-ruby/project/todo_report.rb:66](04-ruby/project/todo_report.rb:66), [04-ruby/project/todo_report.rb:91](04-ruby/project/todo_report.rb:91), [05-cpp/project/main.cpp:487](05-cpp/project/main.cpp:487), [05-cpp/project/main.cpp:549](05-cpp/project/main.cpp:549), [05-cpp/project/main.cpp:674](05-cpp/project/main.cpp:674), [05-cpp/project/main.cpp:754](05-cpp/project/main.cpp:754)).

Definite drift:

- JSON strictness changes. Ruby `JSON.parse` is a library parser ([04-ruby/project/todo_report.rb:112](04-ruby/project/todo_report.rb:112)); C++ uses a custom parser whose number parsing delegates to `std::strtod` and whose object parser replaces duplicate keys in-place ([05-cpp/project/main.cpp:252](05-cpp/project/main.cpp:252), [05-cpp/project/main.cpp:281](05-cpp/project/main.cpp:281)).
- Numeric identity collapses: C++ stores all JSON numbers as `double` ([05-cpp/project/main.cpp:40](05-cpp/project/main.cpp:40)), and grouping uses `js_json_stringify` as a canonical key ([05-cpp/project/main.cpp:588](05-cpp/project/main.cpp:588), [05-cpp/project/main.cpp:726](05-cpp/project/main.cpp:726)). Ruby's parsed numeric objects can distinguish integer and float values as hash keys.
- Top-level non-array behavior changes. Ruby calls `todos.each` and then assumes each `todo` has `key?` ([04-ruby/project/todo_report.rb:146](04-ruby/project/todo_report.rb:146)); C++ simply skips processing unless the top-level value is an array ([05-cpp/project/main.cpp:722](05-cpp/project/main.cpp:722)).
- Unicode formatting/sorting changes for non-ASCII. Ruby string length and comparison operate on Ruby strings; C++ `ljust` uses byte `s.size()`, and string ordering in `py_key_less` uses `std::string` byte lexicographic order ([05-cpp/project/main.cpp:619](05-cpp/project/main.cpp:619), [05-cpp/project/main.cpp:631](05-cpp/project/main.cpp:631)).
- Build/runtime now requires a C++ compiler and libcurl linkage ([05-cpp/project/Makefile:1](05-cpp/project/Makefile:1), [05-cpp/project/Makefile:4](05-cpp/project/Makefile:4)).

Uncertain/equivalent: libcurl and Ruby `Net::HTTP` both do not follow redirects as configured/used here, but TLS, proxy, and URL normalization behavior are not equivalent across libraries.

### 05-cpp -> 06-java

Strategy change: C++ custom parser/libcurl/manual date moves to Java custom parser, `HttpURLConnection`, `LocalDate`, and Java strings ([05-cpp/project/main.cpp:66](05-cpp/project/main.cpp:66), [05-cpp/project/main.cpp:665](05-cpp/project/main.cpp:665), [06-java/project/src/TodoReport.java:81](06-java/project/src/TodoReport.java:81), [06-java/project/src/TodoReport.java:639](06-java/project/src/TodoReport.java:639)).

Preserved behavior: custom value model; custom permissive number/parser shape; Python-like truthiness; canonical-key grouping; no redirects; 10-second connect/read timeout; top-level non-array yields header-only output; normal sorting/counting/output ([05-cpp/project/main.cpp:18](05-cpp/project/main.cpp:18), [05-cpp/project/main.cpp:487](05-cpp/project/main.cpp:487), [05-cpp/project/main.cpp:722](05-cpp/project/main.cpp:722), [06-java/project/src/TodoReport.java:17](06-java/project/src/TodoReport.java:17), [06-java/project/src/TodoReport.java:505](06-java/project/src/TodoReport.java:505), [06-java/project/src/TodoReport.java:680](06-java/project/src/TodoReport.java:680)).

Definite drift:

- HTTP stack changes from libcurl to `HttpURLConnection`; this removes the libcurl dependency but changes supported schemes, proxy/TLS behavior, and error text ([05-cpp/project/main.cpp:673](05-cpp/project/main.cpp:673), [06-java/project/src/TodoReport.java:640](06-java/project/src/TodoReport.java:640)).
- Timeouts change from libcurl connect plus total timeout to Java connect plus read timeout ([05-cpp/project/main.cpp:675](05-cpp/project/main.cpp:675), [05-cpp/project/main.cpp:676](05-cpp/project/main.cpp:676), [06-java/project/src/TodoReport.java:642](06-java/project/src/TodoReport.java:642), [06-java/project/src/TodoReport.java:643](06-java/project/src/TodoReport.java:643)).
- String comparison and padding change to Java UTF-16 code-unit semantics: `pyKeyCompare` uses `String.compareTo`, and `ljust` uses `s.length()` ([06-java/project/src/TodoReport.java:620](06-java/project/src/TodoReport.java:620), [06-java/project/src/TodoReport.java:632](06-java/project/src/TodoReport.java:632)). C++ used byte strings ([05-cpp/project/main.cpp:628](05-cpp/project/main.cpp:628), [05-cpp/project/main.cpp:631](05-cpp/project/main.cpp:631)).
- JSON string decoding changes for raw UTF-8: Java decodes the full response as UTF-8 before parsing ([06-java/project/src/TodoReport.java:660](06-java/project/src/TodoReport.java:660)); C++ parser works on raw bytes in a `std::string` ([05-cpp/project/main.cpp:68](05-cpp/project/main.cpp:68), [05-cpp/project/main.cpp:200](05-cpp/project/main.cpp:200)).

Uncertain/equivalent: The custom number grammar is similar but not exactly specified as JSON in either implementation. Normal fixture numbers are equivalent.

### 06-java -> 07-haskell

Strategy change: Java custom parser plus in-process HTTP becomes Haskell custom parser plus an external `curl` subprocess; Java UTF-16 sorting/padding is deliberately reimplemented ([06-java/project/src/TodoReport.java:639](06-java/project/src/TodoReport.java:639), [07-haskell/project/app/Main.hs:407](07-haskell/project/app/Main.hs:407), [07-haskell/project/app/Main.hs:419](07-haskell/project/app/Main.hs:419)).

Preserved behavior: value model, Python-like truthiness, date validation, canonical-key grouping, Java-style string comparison/padding, top-level non-array header-only output, and output table format ([06-java/project/src/TodoReport.java:505](06-java/project/src/TodoReport.java:505), [06-java/project/src/TodoReport.java:538](06-java/project/src/TodoReport.java:538), [06-java/project/src/TodoReport.java:620](06-java/project/src/TodoReport.java:620), [07-haskell/project/app/Main.hs:333](07-haskell/project/app/Main.hs:333), [07-haskell/project/app/Main.hs:349](07-haskell/project/app/Main.hs:349), [07-haskell/project/app/Main.hs:410](07-haskell/project/app/Main.hs:410), [07-haskell/project/app/Main.hs:481](07-haskell/project/app/Main.hs:481)).

Definite drift:

- HTTP now depends on an executable `curl` and hand-parses `--include` output ([07-haskell/project/app/Main.hs:421](07-haskell/project/app/Main.hs:421), [07-haskell/project/app/Main.hs:440](07-haskell/project/app/Main.hs:440)). Java used `HttpURLConnection` directly ([06-java/project/src/TodoReport.java:640](06-java/project/src/TodoReport.java:640)).
- HTTP timeout changes from Java connect/read timeouts to curl `--max-time 10` plus `--connect-timeout 10` ([06-java/project/src/TodoReport.java:642](06-java/project/src/TodoReport.java:642), [07-haskell/project/app/Main.hs:425](07-haskell/project/app/Main.hs:425)).
- Response decoding changes. Java explicitly decodes bytes as UTF-8 ([06-java/project/src/TodoReport.java:660](06-java/project/src/TodoReport.java:660)); Haskell receives `String` output from `readProcessWithExitCode`, whose byte decoding is runtime/locale mediated ([07-haskell/project/app/Main.hs:421](07-haskell/project/app/Main.hs:421)).
- Build/runtime changes to Cabal offline build/run and a runtime `curl` dependency ([07-haskell/project/run.sh:11](07-haskell/project/run.sh:11), [07-haskell/project/todo-report-hs.cabal:11](07-haskell/project/todo-report-hs.cabal:11)).

Uncertain/equivalent: Redirect behavior remains no-follow in ordinary curl default and Java's `setInstanceFollowRedirects(false)`, but error messages and protocol support differ.

### 07-haskell -> 08-common-lisp

Strategy change: Haskell custom parser/process/date becomes Common Lisp custom parser/process/date, still using external `curl` and explicit Java/Python compatibility helpers ([07-haskell/project/app/Main.hs:51](07-haskell/project/app/Main.hs:51), [08-common-lisp/project/main.lisp:3](08-common-lisp/project/main.lisp:3), [08-common-lisp/project/main.lisp:202](08-common-lisp/project/main.lisp:202), [08-common-lisp/project/main.lisp:432](08-common-lisp/project/main.lisp:432)).

Preserved behavior: custom JSON value model; Python-like truthiness; canonical-key grouping; Java-style comparison and padding; curl status parsing; header-only output for non-array input; same normal output ([07-haskell/project/app/Main.hs:333](07-haskell/project/app/Main.hs:333), [07-haskell/project/app/Main.hs:373](07-haskell/project/app/Main.hs:373), [07-haskell/project/app/Main.hs:410](07-haskell/project/app/Main.hs:410), [08-common-lisp/project/main.lisp:299](08-common-lisp/project/main.lisp:299), [08-common-lisp/project/main.lisp:346](08-common-lisp/project/main.lisp:346), [08-common-lisp/project/main.lisp:369](08-common-lisp/project/main.lisp:369), [08-common-lisp/project/main.lisp:453](08-common-lisp/project/main.lisp:453)).

Definite drift:

- Date/fetch ordering changes around midnight or slow/failing requests. Haskell fetches first, then gets today's date ([07-haskell/project/app/Main.hs:531](07-haskell/project/app/Main.hs:531), [07-haskell/project/app/Main.hs:533](07-haskell/project/app/Main.hs:533), [07-haskell/project/app/Main.hs:534](07-haskell/project/app/Main.hs:534)). Lisp's main call computes `today-universal-day` as an argument to `process-todos` before passing fetched data in source order ([08-common-lisp/project/main.lisp:493](08-common-lisp/project/main.lisp:493)).
- Date representation changes from Haskell `Day` to Common Lisp universal time at midnight encoded with timezone 0 ([07-haskell/project/app/Main.hs:349](07-haskell/project/app/Main.hs:349), [08-common-lisp/project/main.lisp:344](08-common-lisp/project/main.lisp:344), [08-common-lisp/project/main.lisp:447](08-common-lisp/project/main.lisp:447)).
- Parser/runtime character behavior changes from Haskell `String` operations to Common Lisp implementation characters; this matters for non-ASCII, invalid Unicode, and `code-char` support ([07-haskell/project/app/Main.hs:410](07-haskell/project/app/Main.hs:410), [08-common-lisp/project/main.lisp:72](08-common-lisp/project/main.lisp:72), [08-common-lisp/project/main.lisp:109](08-common-lisp/project/main.lisp:109)).
- Build/runtime changes from Cabal/GHC to SBCL script execution ([07-haskell/project/run.sh:11](07-haskell/project/run.sh:11), [08-common-lisp/project/run.sh:10](08-common-lisp/project/run.sh:10)).

Uncertain/equivalent: For valid ASCII JSON and dates away from midnight boundaries, behavior is equivalent. Common Lisp argument evaluation order is left-to-right in the relevant implementation path, but portability of subtle evaluation/character behavior depends on implementation details.

### 08-common-lisp -> 09-zig

Strategy change: Common Lisp script becomes a Zig executable with allocator-threaded context, explicit byte-slice parser, manual insertion sort, external `curl`, and external `date` ([08-common-lisp/project/main.lisp:1](08-common-lisp/project/main.lisp:1), [09-zig/project/src/main.zig:29](09-zig/project/src/main.zig:29), [09-zig/project/src/main.zig:45](09-zig/project/src/main.zig:45), [09-zig/project/src/main.zig:626](09-zig/project/src/main.zig:626), [09-zig/project/src/main.zig:645](09-zig/project/src/main.zig:645)).

Preserved behavior: custom parser/value model; Python-like truthiness; `undefined` for missing object fields; canonical grouping; Java-style string compare/length; curl HTTP; same output algorithm ([08-common-lisp/project/main.lisp:299](08-common-lisp/project/main.lisp:299), [08-common-lisp/project/main.lisp:309](08-common-lisp/project/main.lisp:309), [08-common-lisp/project/main.lisp:404](08-common-lisp/project/main.lisp:404), [09-zig/project/src/main.zig:402](09-zig/project/src/main.zig:402), [09-zig/project/src/main.zig:418](09-zig/project/src/main.zig:418), [09-zig/project/src/main.zig:502](09-zig/project/src/main.zig:502), [09-zig/project/src/main.zig:657](09-zig/project/src/main.zig:657)).

Definite drift:

- Today's date source changes from Common Lisp `get-decoded-time` to an external `date +%Y-%m-%d` command ([08-common-lisp/project/main.lisp:447](08-common-lisp/project/main.lisp:447), [09-zig/project/src/main.zig:645](09-zig/project/src/main.zig:645)). This adds PATH/locale/coreutils dependency and changes failure modes.
- Error propagation changes from Lisp conditions printed by `handler-case` to Zig context strings plus `error.App` ([08-common-lisp/project/main.lisp:13](08-common-lisp/project/main.lisp:13), [08-common-lisp/project/main.lisp:491](08-common-lisp/project/main.lisp:491), [09-zig/project/src/main.zig:33](09-zig/project/src/main.zig:33), [09-zig/project/src/main.zig:711](09-zig/project/src/main.zig:711)).
- String/encoding behavior changes from Lisp character strings to Zig byte slices with explicit UTF-8 decoding for Java-length/comparison helpers ([08-common-lisp/project/main.lisp:361](08-common-lisp/project/main.lisp:361), [09-zig/project/src/main.zig:492](09-zig/project/src/main.zig:492)).
- Build/runtime changes to `zig build` and an installed binary ([09-zig/project/run.sh:10](09-zig/project/run.sh:10), [09-zig/project/build.zig:7](09-zig/project/build.zig:7)).

Uncertain/equivalent: The HTTP subprocess command is essentially equivalent for normal responses. Unicode equivalence depends on valid UTF-8 and host Lisp character behavior.

### 09-zig -> 10-rust

Strategy change: Zig allocator/context code becomes Rust owned `String`/`Vec` code with the same subprocess strategy and manual parser ([09-zig/project/src/main.zig:14](09-zig/project/src/main.zig:14), [10-rust/project/src/main.rs:4](10-rust/project/src/main.rs:4), [10-rust/project/src/main.rs:36](10-rust/project/src/main.rs:36), [10-rust/project/src/main.rs:729](10-rust/project/src/main.rs:729)).

Preserved behavior: custom JSON model/parser; Python-like truthiness; missing fields as undefined; date via `date`; HTTP via `curl`; Java-style sorting and padding; insertion-sort output ordering ([09-zig/project/src/main.zig:402](09-zig/project/src/main.zig:402), [09-zig/project/src/main.zig:645](09-zig/project/src/main.zig:645), [09-zig/project/src/main.zig:676](09-zig/project/src/main.zig:676), [10-rust/project/src/main.rs:448](10-rust/project/src/main.rs:448), [10-rust/project/src/main.rs:752](10-rust/project/src/main.rs:752), [10-rust/project/src/main.rs:785](10-rust/project/src/main.rs:785)).

Definite drift:

- Raw JSON string bytes change. Zig appends raw non-escape bytes to a byte buffer and only decodes when needed for Java comparisons ([09-zig/project/src/main.zig:109](09-zig/project/src/main.zig:109), [09-zig/project/src/main.zig:492](09-zig/project/src/main.zig:492)). Rust stores a `String` and, for non-escaped bytes, pushes `c as char`, converting each byte to a Unicode scalar rather than preserving UTF-8 byte sequences ([10-rust/project/src/main.rs:122](10-rust/project/src/main.rs:122), [10-rust/project/src/main.rs:172](10-rust/project/src/main.rs:172)).
- Subprocess API and error text change from Zig `std.process.run` with `term` matching to Rust `Command::output` and `ExitStatus` handling ([09-zig/project/src/main.zig:626](09-zig/project/src/main.zig:626), [10-rust/project/src/main.rs:729](10-rust/project/src/main.rs:729)).
- Build/runtime changes to Cargo debug build with no dependencies ([10-rust/project/run.sh:10](10-rust/project/run.sh:10), [10-rust/project/Cargo.toml:6](10-rust/project/Cargo.toml:6)).

Uncertain/equivalent: For ASCII JSON strings, HTTP status parsing, date comparison, sorting, and output are equivalent.

### 10-rust -> 11-go

Strategy change: Rust custom implementation becomes final Go custom implementation. It does not recover Go's original stdlib JSON/HTTP/date strategy; instead it ports the Rust-era dynamic parser, truthiness, date arithmetic, Java string comparison, `curl`, and `date` shell-outs ([10-rust/project/src/main.rs:4](10-rust/project/src/main.rs:4), [10-rust/project/src/main.rs:729](10-rust/project/src/main.rs:729), [11-go/project/main.go:14](11-go/project/main.go:14), [11-go/project/main.go:862](11-go/project/main.go:862)).

Preserved behavior: Python-like truthiness; arbitrary JSON user ids; grouping by JSON stringification; top-level non-array header-only output; external `curl`; external `date`; Java-style sorting/padding; same output shape ([10-rust/project/src/main.rs:448](10-rust/project/src/main.rs:448), [10-rust/project/src/main.rs:536](10-rust/project/src/main.rs:536), [10-rust/project/src/main.rs:729](10-rust/project/src/main.rs:729), [10-rust/project/src/main.rs:752](10-rust/project/src/main.rs:752), [11-go/project/main.go:554](11-go/project/main.go:554), [11-go/project/main.go:662](11-go/project/main.go:662), [11-go/project/main.go:862](11-go/project/main.go:862), [11-go/project/main.go:885](11-go/project/main.go:885)).

Definite drift:

- Raw non-escaped JSON string handling changes again. Rust pushes each raw byte as a char into a UTF-8 `String` ([10-rust/project/src/main.rs:172](10-rust/project/src/main.rs:172)); final Go writes raw bytes to a `strings.Builder` ([11-go/project/main.go:206](11-go/project/main.go:206)). This changes non-ASCII raw JSON strings.
- Numeric formatting differs at extremes: Rust casts integer-valued `f64` to `i64` in `append_number` ([10-rust/project/src/main.rs:401](10-rust/project/src/main.rs:401)); Go adds explicit clamps around int64 limits before `FormatInt` ([11-go/project/main.go:401](11-go/project/main.go:401), [11-go/project/main.go:405](11-go/project/main.go:405)).
- Build/runtime changes from Cargo to Go build, but still requires external `curl` and `date` at runtime ([10-rust/project/run.sh:10](10-rust/project/run.sh:10), [11-go/project/run.sh:10](11-go/project/run.sh:10), [11-go/project/main.go:863](11-go/project/main.go:863), [11-go/project/main.go:886](11-go/project/main.go:886)).

Uncertain/equivalent: For ASCII fixture JSON, final Go is intentionally close to Rust. Error strings differ by language/runtime for subprocess launch failures and parser edge cases.

## 01-go/project vs 11-go/project

The endpoints are both Go CLIs, but they are semantically different programs.

Original 01-go:

- Uses typed structs: `UserID int`, `Completed bool`, `DueDate string` ([01-go/project/main.go:12](01-go/project/main.go:12)).
- Uses Go's `http.Client{Timeout: 10 * time.Second}` ([01-go/project/main.go:31](01-go/project/main.go:31)).
- Uses Go's `encoding/json.Decoder` into `[]Todo` ([01-go/project/main.go:44](01-go/project/main.go:44)).
- Uses Go's local `time.Now`, local midnight, and `time.ParseInLocation(time.DateOnly, ...)` ([01-go/project/main.go:50](01-go/project/main.go:50), [01-go/project/main.go:64](01-go/project/main.go:64)).
- Sorts concrete `Summary` rows by integer fields and integer user id ([01-go/project/main.go:79](01-go/project/main.go:79)).
- Builds/runs directly with `go run .` and declares Go 1.22 ([01-go/project/run.sh:10](01-go/project/run.sh:10), [01-go/project/go.mod:3](01-go/project/go.mod:3)).

Final 11-go:

- Defines a JavaScript-like dynamic value enum with undefined/null/bool/number/string/array/object ([11-go/project/main.go:14](11-go/project/main.go:14)).
- Implements a custom JSON parser and serializer ([11-go/project/main.go:55](11-go/project/main.go:55), [11-go/project/main.go:358](11-go/project/main.go:358), [11-go/project/main.go:469](11-go/project/main.go:469)).
- Treats `completed` through Python-like truthiness, including truthy undefined and falsey empty arrays/objects ([11-go/project/main.go:554](11-go/project/main.go:554), [11-go/project/main.go:904](11-go/project/main.go:904)).
- Represents dates as integer day counts from a civil-date algorithm and obtains today from `date +%Y-%m-%d` ([11-go/project/main.go:625](11-go/project/main.go:625), [11-go/project/main.go:885](11-go/project/main.go:885)).
- Fetches via external `curl --silent --show-error --include --max-time 10 --connect-timeout 10` and hand-parses the HTTP response ([11-go/project/main.go:801](11-go/project/main.go:801), [11-go/project/main.go:862](11-go/project/main.go:862)).
- Sorts arbitrary JSON user ids through a Python-key grouping and Java UTF-16 string comparator ([11-go/project/main.go:739](11-go/project/main.go:739), [11-go/project/main.go:763](11-go/project/main.go:763)).
- Builds a binary with `go build -o todo_report .`, declares Go 1.26, and still relies on external runtime commands ([11-go/project/run.sh:10](11-go/project/run.sh:10), [11-go/project/go.mod:3](11-go/project/go.mod:3)).

Concrete semantic gaps:

- Wrongly typed JSON that 01-go rejects can be counted, grouped, or silently ignored by 11-go.
- Missing `completed` is not equivalent: 01-go decodes absent bool as false and then parses due date; 11-go sees undefined as truthy and counts completed ([01-go/project/main.go:61](01-go/project/main.go:61), [11-go/project/main.go:554](11-go/project/main.go:554), [11-go/project/main.go:905](11-go/project/main.go:905)).
- Missing `dueDate` is not equivalent when `completed` is false: 01-go sees empty string from the struct and emits Go's parse error; 11-go parses an explicit undefined value and emits its own compatibility error ([01-go/project/main.go:64](01-go/project/main.go:64), [11-go/project/main.go:658](11-go/project/main.go:658)).
- Top-level non-array is not equivalent: 01-go decode into `[]Todo` fails for object/scalar; 11-go prints only the header ([01-go/project/main.go:45](01-go/project/main.go:45), [11-go/project/main.go:901](11-go/project/main.go:901), [11-go/project/main.go:925](11-go/project/main.go:925)).
- HTTP/runtime failure modes are substantially different: 01-go needs only Go runtime/library networking; 11-go needs `curl` and `date` in PATH and parses their output ([11-go/project/main.go:863](11-go/project/main.go:863), [11-go/project/main.go:886](11-go/project/main.go:886)).

## Conclusions

The chain preserved the verifier fixture's observable output, but it did not preserve the program's broader contract. Translation accumulated compatibility scaffolding around whatever the immediately previous stage did. Once a drift appeared, later stages usually preserved it as if it were specification: Python-like truthiness, totalized user-id sorting, custom JSON parsing, Java string semantics, external curl, and external date all became part of the inherited behavior.

The most damaging pattern is that the verifier exercised only a valid fixture. That allowed malformed inputs, unusual JSON types, duplicate/numeric edge cases, redirects, slow bodies, non-ASCII strings, date-boundary timing, missing external commands, and build/runtime dependencies to drift without detection. The final Go program is therefore fixture-equivalent, not semantically equivalent, to the original Go program.

