#!/usr/bin/env sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: ./run.sh <url>" >&2
  exit 2
fi

cd "$(dirname "$0")"
export RUSTC="$(rustup which rustc)"
exec "$(rustup which cargo)" run --quiet -- "$1"
