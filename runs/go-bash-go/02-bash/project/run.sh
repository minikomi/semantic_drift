#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: ./run.sh <url>" >&2
  exit 2
fi

cd "$(dirname "$0")"

if ! command -v jq >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    brew bundle --quiet --no-lock --file="Brewfile"
  else
    echo "missing dependency: jq" >&2
    exit 1
  fi
fi

url=$1
body_file=$(mktemp)
trap 'rm -f "$body_file"' EXIT

if ! status_code=$(curl -sS --max-time 10 -w '%{http_code}' -o "$body_file" "$url"); then
  exit 1
fi

case "$status_code" in
  2??) ;;
  *)
    echo "bad status: $status_code" >&2
    exit 1
    ;;
esac

today=$(date '+%Y-%m-%d')

echo "USER  COMPLETED  MISSED"

jq -r --arg today "$today" '
  reduce .[] as $todo
    ({};
      ($todo.userId | tostring) as $user
      | .[$user].userId = $todo.userId
      | .[$user].completed = ((.[$user].completed // 0) + (if $todo.completed then 1 else 0 end))
      | .[$user].missed = ((.[$user].missed // 0) + (if (($todo.completed | not) and ($todo.dueDate < $today)) then 1 else 0 end))
    )
  | [.[]]
  | sort_by([-.completed, -.missed, .userId])
  | .[]
  | [.userId, .completed, .missed]
  | @tsv
' "$body_file" | while IFS=$'\t' read -r user_id completed missed; do
  printf '%-5d %-10d %d\n' "$user_id" "$completed" "$missed"
done
