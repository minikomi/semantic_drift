#!/usr/bin/env sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: ./run.sh <url>" >&2
  exit 2
fi

cd "$(dirname "$0")"
if [ ! -f target/semantic-drift-todos-1.0.0.jar ]; then
  mvn -q -DskipTests package >/dev/null 2>&1
fi
exec java -jar target/semantic-drift-todos-1.0.0.jar "$1"
