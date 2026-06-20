#!/usr/bin/env sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: ./run.sh <url>" >&2
  exit 2
fi

cd "$(dirname "$0")"

if [ ! -d vendor ]; then
  composer install --no-interaction --no-progress --quiet
else
  composer install --no-interaction --no-progress --quiet
fi

exec php src/main.php "$1"
