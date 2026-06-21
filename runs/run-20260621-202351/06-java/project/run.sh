#!/usr/bin/env sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: ./run.sh <url>" >&2
  exit 2
fi

cd "$(dirname "$0")"

mkdir -p build
javac -encoding UTF-8 -d build src/TodoReport.java
exec java -cp build TodoReport "$1"
