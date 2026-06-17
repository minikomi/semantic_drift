#!/usr/bin/env sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: ./run.sh <url>" >&2
  exit 2
fi

cd "$(dirname "$0")"
bundle check >/dev/null 2>&1 || bundle install --quiet
exec bundle exec ruby -rbundler/setup -Ilib -r semantic_drift_todos -e 'SemanticDriftTodos.main(ARGV)' "$1"
