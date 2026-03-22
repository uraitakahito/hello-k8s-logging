#!/bin/sh
set -e

VARIANT="${1:-blue}"
SRC="/usr/share/nginx/html/index-${VARIANT}.html"

if [ ! -f "$SRC" ]; then
  echo "Error: unknown variant '${VARIANT}' (available: blue, green)" >&2
  exit 1
fi

cp "$SRC" /usr/share/nginx/html/index.html
exec nginx -g 'daemon off;'
