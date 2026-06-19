#!/usr/bin/env sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: ./run.sh <url>" >&2
  exit 2
fi

cd "$(dirname "$0")"
bundle install --quiet --path vendor/bundle
exec bundle exec ruby lib/main.rb "$1"
