# Semantic Drift

Initial scaffold for the fake API used by the Semantic Drift harness.

## Run

```sh
go run ./fake_api
```

The server listens on `127.0.0.1:8899` by default.

```sh
curl http://127.0.0.1:8899/health
curl http://127.0.0.1:8899/todos
```

Override the bind address with `SEMANTIC_DRIFT_ADDR`:

```sh
SEMANTIC_DRIFT_ADDR=127.0.0.1:9000 go run ./fake_api
```

## Conformance Tests

The generated programs, fake API, and conformance oracle all use the machine's
current local date. The fixture uses dates from 1900 through 2999 so its expected
result remains useful without replacing the system clock.

Run:

```sh
uv run pytest
```

The first test starts the Go fake API configured for the project and requests:

```sh
POST http://127.0.0.1:8899/conform
```

The fake API runs the project against `/todos`, calculates the expected output
using its own system date, and compares stdout exactly.

To check one generated project during an agent loop:

```sh
uv run python -m semantic_drift conform runs/latest/01-go/project
```

Each generated project owns its runtime wrapper:

```text
runs/latest/<step>/project/run.sh <url>
```

## Rewrite Prompt

Render the reusable prompt without running an agent:

```sh
uv run python -m semantic_drift prompt rewrite \
  --source-language Go \
  --target-language TypeScript \
  --source-dir runs/latest/01-go \
  --target-dir runs/latest/02-typescript
```

Run a fresh Codex instance with that same prompt:

```sh
uv run python -m semantic_drift rewrite \
  --source-language Go \
  --target-language TypeScript \
  --source-dir runs/latest/01-go \
  --target-dir runs/latest/02-typescript
```

For this local experiment, rewrite runs child Codex with sandbox bypass by
default so it can run the conformance server, connect to localhost, and use
normal tool caches:

```sh
uv run python -m semantic_drift rewrite \
  --source-language Go \
  --target-language TypeScript \
  --source-dir runs/latest/01-go \
  --target-dir runs/latest/02-typescript
```

The child Codex process receives only the rendered prompt as its task prompt.

## Full Chain

Run the configured chain:

```text
Go -> TypeScript -> Python -> Ruby -> C++ -> Java -> Haskell -> Common Lisp -> Zig -> Rust -> Go
```

```sh
scripts/run_chain.sh
```

The script stops on the first rewrite or conformance failure. It writes steps to:

```text
runs/latest/01-go
runs/latest/02-typescript
runs/latest/03-python
runs/latest/04-ruby
runs/latest/05-cpp
runs/latest/06-java
runs/latest/07-haskell
runs/latest/08-common-lisp
runs/latest/09-zig
runs/latest/10-rust
runs/latest/11-go
```
