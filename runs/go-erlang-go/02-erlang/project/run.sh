#!/usr/bin/env sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: ./run.sh <url>" >&2
  exit 2
fi

cd "$(dirname "$0")"
rebar3 escriptize >/dev/null
exec ./_build/default/bin/todo_summary "$1"
