#!/usr/bin/env sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: ./run.sh <url>" >&2
  exit 2
fi

cd "$(dirname "$0")"
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build build --config Release >/dev/null
exec ./build/todo_summary "$1"
