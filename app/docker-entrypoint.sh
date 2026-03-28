#!/bin/sh
set -e

VARIANT="${VARIANT:-blue}"
SRC="/usr/share/nginx/html/index-${VARIANT}.html"

if [ ! -f "$SRC" ]; then
  echo "Error: unknown variant '${VARIANT}' (available: blue, green)" >&2
  exit 1
fi

ln -sf "$SRC" /usr/share/nginx/html/index.html
echo "hello-k8s: serving variant '${VARIANT}'"
exec "$@"
