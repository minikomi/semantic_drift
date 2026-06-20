#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: ./run.sh <url>" >&2
  exit 2
fi

cd "$(dirname "$0")"

go mod download
go build -o semantic_drift_todos .
./semantic_drift_todos "$1"
