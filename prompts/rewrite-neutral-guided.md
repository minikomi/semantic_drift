# Task

You are translating one implementation into another language while
preserving observable behavior exactly.

Use only the information in this prompt and the files in the source directory.

## Inputs

- Source language: $SOURCE_LANGUAGE
- Target language: $TARGET_LANGUAGE
- Source project directory: `$SOURCE_PROJECT_DIR`
- Target project directory: `$TARGET_PROJECT_DIR`

## Behavioral Source

Derive the program behavior from the source project. Do not rely on a restated
specification in this prompt.

The verification command checks the target against one valid example. Passing
it is necessary but not sufficient; preserve source behavior beyond that
example as well.

Do not hard-code example data, expected output, timestamps, service responses,
or other verification constants into the program logic or `run.sh`.

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

It must change to its own directory before building/running so it works from
any caller directory.

It must build and run the program normally and use the machine's system date and
time without overriding them.

Do not create or modify workspace-level entry scripts.

## Source Material

Read the source project in:

```text
$SOURCE_PROJECT_DIR
```

Preserve the observable behavior, not incidental implementation structure.

## Verification

After writing the target project, run the verification command:

```sh
$CHECK_COMMAND $TARGET_PROJECT_DIR
```

The command runs `run.sh` against a valid input, captures its stdout, and checks
those exact bytes. It does not run or inspect the target project in any other
way.

You may also run `run.sh` directly to diagnose build or runtime failures. Do not
override the system clock or restructure the runtime command for verification.

If verification fails, inspect stdout/stderr, repair the target project, and run
the same command again. Continue until the JSON response reports `"passed": true`
or until you hit a real blocker.

Do not change the source project, input service, verification tool, or this prompt
to make the target pass. Do not inspect fixtures as a way to hard-code the
answer; translate the source behavior and use verification only as feedback.

Use idiomatic, mainstream ecosystem libraries rather than lower-level standard
library facilities when a widely adopted library exists for the task. Do not
avoid dependencies merely to make the project self-contained.

Declare dependencies using the target language's conventional project tooling,
and make `run.sh` install or resolve them reproducibly before running.

## Deliverable

When finished, report:

- files created or changed under `$TARGET_PROJECT_DIR`
- the final verification command
- whether it passed
