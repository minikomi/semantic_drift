#!/usr/bin/env sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: ./run.sh <url>" >&2
  exit 2
fi

cd "$(dirname "$0")"
if [ ! -d node_modules ]; then
  npm ci --silent
fi
npm run build --silent
exec npm run start --silent -- "$1"
