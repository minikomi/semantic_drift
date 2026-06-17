# Semantic Drift Rewrite Task

You are translating one generated implementation into another language while
preserving observable behavior exactly.

Use only the information in this prompt and the files in the source directory.

## Inputs

- Source language: $SOURCE_LANGUAGE
- Target language: $TARGET_LANGUAGE
- Source step directory: `$SOURCE_DIR`
- Source project directory: `$SOURCE_PROJECT_DIR`
- Target step directory: `$TARGET_DIR`
- Target project directory: `$TARGET_PROJECT_DIR`
- Repository root: `$REPO_ROOT`

## Behavioral Source

Derive the program behavior from the source project. Do not rely on a restated
specification in this prompt.

The conformance command is the oracle for whether the translated project
preserves the observable behavior.

## Required Target Shape

Create or replace only the target project directory:

```text
$TARGET_PROJECT_DIR
```

The target project must contain all source/dependency files required to build
and run the implementation in $TARGET_LANGUAGE.

You may install any libraries, tools or environment required.

The target project must include:

```text
run.sh
```

`run.sh` must accept exactly one argument, the todos URL:

```sh
./run.sh http://127.0.0.1:8899/todos
```

It should change to its own directory before building/running so it works when
called from the repository root.

Do not create or modify repository-level entrance scripts.

## Source Material

Read the source project in:

```text
$SOURCE_PROJECT_DIR
```

Preserve the observable behavior, not incidental implementation structure.

## Conformance

After writing the target project, run:

```sh
uv run python -m semantic_drift conform $TARGET_PROJECT_DIR
```

If conformance fails, inspect stdout/stderr, repair the target project, and run
the same command again. Continue until it passes or until you hit a real blocker.

Do not change the source project, todos API, seed expected output, conformance
harness, or this prompt to make the target pass. Do not inspect fixtures as a way
to hard-code the answer; translate the source behavior and use conformance only
as feedback.

Make the code as idiomatic as possible - that includes using common libraries for
tasks, instead of just relying on the standard library. Use the most popular build
tool or project management for the language too, if required.

Try to use libraries when they make sense, instead of rolling your own implementation.

## Deliverable

When finished, report:

- files created or changed under `$TARGET_PROJECT_DIR`
- the final conformance command
- whether it passed
