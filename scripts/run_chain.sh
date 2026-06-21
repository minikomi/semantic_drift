#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

run_dir=${RUN_DIR:-"runs/run-$(date +%Y%m%d-%H%M%S)"}
baseline_dir=${BASELINE_DIR:-runs/latest/01-go/project}
resume=${RESUME:-0}
prompt_variant=${PROMPT_VARIANT:-neutral}

if [[ -e "$run_dir" ]]; then
  if [[ "$resume" != "1" ]]; then
    printf 'output directory already exists: %s\n' "$run_dir" >&2
    printf 'set RESUME=1 to continue that chain\n' >&2
    exit 2
  fi
elif [[ "$resume" == "1" ]]; then
  printf 'cannot resume missing output directory: %s\n' "$run_dir" >&2
  exit 2
else
  mkdir -p "$run_dir/01-go"
  cp -R "$baseline_dir" "$run_dir/01-go/project"
fi

languages=(
  "Go"
  "TypeScript"
  "Python"
  "Ruby"
  "C++"
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
  "05-cpp"
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
  archived_target="${run_dir}/${target_step}/project"

  if [[ "$resume" == "1" && -f "$archived_target/run.sh" ]]; then
    printf '\n==> %s -> %s (%s -> %s)\n' \
      "$source_language" "$target_language" "$source_step" "$target_step"
    printf '    already archived; skipping\n'
    continue
  fi

  work_dir=$(mktemp -d /tmp/work.XXXXXX)
  source_dir="${work_dir}/input"
  target_dir="${work_dir}/output"
  target_project="${target_dir}/project"
  mkdir -p "$source_dir"
  cp -R "${run_dir}/${source_step}/project" "$source_dir/project"
  cp scripts/verify_project.py "$work_dir/verify.py"

  printf '\n==> %s -> %s (%s -> %s)\n' \
    "$source_language" "$target_language" "$source_step" "$target_step"

  uv run python -m semantic_drift rewrite \
    --source-language "$source_language" \
    --target-language "$target_language" \
    --source-dir "$source_dir" \
    --target-dir "$target_dir" \
    --agent-workspace "$work_dir" \
    --prompt-variant "$prompt_variant" \
    --check-command "python3 $work_dir/verify.py"

  uv run python -m semantic_drift conform "$target_project"
  mkdir -p "${run_dir}/${target_step}"
  cp -R "$target_project" "${run_dir}/${target_step}/project"
  rm -rf "$work_dir"
done

printf '\nTranslation chain complete: %s\n' "$run_dir"
