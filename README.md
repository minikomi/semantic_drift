# Semantic Drift

Initial scaffold for the deterministic fake API used by the Semantic Drift harness.

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

The generated programs read the system clock directly. The pytest harness keeps
time deterministic by running generated projects through `faketime` at:

```text
2026-06-16 12:00:00
```

Install the test tools, then run:

```sh
uv run pytest
```

The first test starts the Go fake API, runs:

```sh
runs/latest/01-go/project/run.sh http://127.0.0.1:8899/todos
```

under `faketime`, and compares stdout exactly with `seed/expected.txt`.

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
Go -> TypeScript -> Python -> Ruby -> Bash -> Java -> Haskell -> Common Lisp -> Zig -> Rust -> Go
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
runs/latest/05-bash
runs/latest/06-java
runs/latest/07-haskell
runs/latest/08-common-lisp
runs/latest/09-zig
runs/latest/10-rust
runs/latest/11-go
```
