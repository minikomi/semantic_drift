#!/usr/bin/env sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: ./run.sh <url>" >&2
  exit 2
fi

cd "$(dirname "$0")"

QUICKLISP_DIR="$PWD/.quicklisp"
if [ ! -f "$QUICKLISP_DIR/setup.lisp" ]; then
  mkdir -p "$QUICKLISP_DIR"
  curl -fsSLo "$QUICKLISP_DIR/quicklisp.lisp" https://beta.quicklisp.org/quicklisp.lisp
  sbcl --noinform --disable-debugger --load "$QUICKLISP_DIR/quicklisp.lisp" \
    --eval "(quicklisp-quickstart:install :path \"$QUICKLISP_DIR/\")" \
    --eval "(ql-util:without-prompting (ql:add-to-init-file))" \
    --quit >/dev/null
fi

exec sbcl --noinform --disable-debugger \
  --load "$QUICKLISP_DIR/setup.lisp" \
  --eval "(pushnew #P\"$PWD/\" asdf:*central-registry* :test #'equal)" \
  --eval "(ql:quickload :todo-summary :silent t)" \
  --eval "(todo-summary:main)" \
  --quit \
  -- "$1"
