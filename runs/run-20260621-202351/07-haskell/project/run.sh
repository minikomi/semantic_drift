#!/usr/bin/env sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: ./run.sh <url>" >&2
  exit 2
fi

cd "$(dirname "$0")"

cabal v2-build --offline exe:todo-report >/dev/null
exec cabal v2-run --offline exe:todo-report -- "$1"
