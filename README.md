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

The first test starts the Go fake API, runs the project against `/todos`, and
submits the captured stdout as the body of:

```sh
POST http://127.0.0.1:8899/conform
```

The fake API calculates the expected output using its own system date and
compares the submitted bytes exactly. It does not know the project path or run
generated code itself.

To check one generated project during an agent loop:

```sh
uv run python -m semantic_drift conform runs/latest/01-go/project
```

The standalone `conform` command starts and stops the API itself. During a
rewrite, where the API is already running, the child process uses:

```sh
uv run python -m semantic_drift submit runs/latest/01-go/project
```

Each generated project owns its runtime wrapper:

```text
runs/latest/<step>/project/run.sh <url>
```

## Rewrite Prompt

Two prompt conditions are retained as separate files:

- `prompts/rewrite.md` is the original prompt, including experiment terminology
  and the instruction to prefer mainstream ecosystem libraries.
- `prompts/rewrite-neutral.md` is the second prompt used by isolated chain runs;
  it removes experiment labels and library-selection guidance.
- `prompts/rewrite-neutral-guided.md` is the controlled third condition: it is
  identical to the neutral prompt except that the original library-selection
  paragraph is restored.

The prompt CLI defaults to `original`. Select the second condition with
`--prompt-variant neutral`. The full-chain script defaults to `neutral`; override
it with `PROMPT_VARIANT=original`.

Render the reusable prompt without running an agent:

```sh
uv run python -m semantic_drift prompt rewrite \
  --prompt-variant neutral \
  --source-language Go \
  --target-language TypeScript \
  --source-dir runs/latest/01-go \
  --target-dir runs/latest/02-typescript
```

Run a fresh Codex instance with that same prompt:

```sh
uv run python -m semantic_drift rewrite \
  --prompt-variant neutral \
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

The script stops on the first rewrite or verification failure. By default it
writes steps to a timestamped directory under `runs/`. Set `RUN_DIR` to choose
an explicit new archive directory:

```sh
RUN_DIR=runs/control-01 scripts/run_chain.sh
```

Resume an interrupted chain without rerunning archived steps:

```sh
RESUME=1 RUN_DIR=runs/control-01 scripts/run_chain.sh
```

Each translation runs in a separate neutral temporary workspace containing
only its immediate source project, an empty target location, and the verification
helper. Repository names, historical runs, archive paths, and orchestration
package names are not exposed to the child process.
