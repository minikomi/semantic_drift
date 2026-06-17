#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

languages=(
  "Go"
  "TypeScript"
  "Python"
  "Ruby"
  "PHP"
  "Java"
  "Haskell"
  "Common Lisp"
  "Zig"
  "Rust"
  "Go"
)

steps=(
  "01-go"
  "02-typescript"
  "03-python"
  "04-ruby"
  "05-php"
  "06-java"
  "07-haskell"
  "08-common-lisp"
  "09-zig"
  "10-rust"
  "11-go"
)

for ((i = 0; i < ${#steps[@]} - 1; i++)); do
  source_language=${languages[$i]}
  target_language=${languages[$((i + 1))]}
  source_step=${steps[$i]}
  target_step=${steps[$((i + 1))]}
  source_dir="runs/latest/${source_step}"
  target_dir="runs/latest/${target_step}"
  target_project="${target_dir}/project"

  printf '\n==> %s -> %s (%s -> %s)\n' \
    "$source_language" "$target_language" "$source_step" "$target_step"

  uv run python -m semantic_drift rewrite \
    --source-language "$source_language" \
    --target-language "$target_language" \
    --source-dir "$source_dir" \
    --target-dir "$target_dir"

  uv run python -m semantic_drift conform "$target_project"
done

printf '\nSemantic Drift chain complete.\n'
