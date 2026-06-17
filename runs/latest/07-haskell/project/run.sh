#!/usr/bin/env sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: ./run.sh <url>" >&2
  exit 2
fi

cd "$(dirname "$0")"
if [ ! -x dist-newstyle/build/*/*/semantic-drift-todos-1.0.0/x/semantic-drift-todos/build/semantic-drift-todos/semantic-drift-todos ] 2>/dev/null; then
  cabal build -v0 >/dev/null 2>&1
fi

exec cabal exec -v0 semantic-drift-todos -- "$1"
