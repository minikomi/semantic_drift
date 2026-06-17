#!/usr/bin/env sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: ./run.sh <url>" >&2
  exit 2
fi

cd "$(dirname "$0")"
if [ ! -f vendor/autoload.php ]; then
  composer install --quiet --no-interaction
fi

exec php bin/semantic-drift-todos.php "$1"
