#!/usr/bin/env sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: ./run.sh <url>" >&2
  exit 2
fi

cd "$(dirname "$0")"
cabal v2-build exe:todo-summary >/dev/null 2>&1
exec cabal v2-run exe:todo-summary -- "$1"
