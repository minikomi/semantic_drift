#!/usr/bin/env sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: ./run.sh <url>" >&2
  exit 2
fi

cd "$(dirname "$0")"
mvn -q -DskipTests package >/dev/null 2>&1
exec java -jar target/todo-summary-1.0.0.jar "$1"
