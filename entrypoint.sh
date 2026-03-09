#!/bin/sh
set -e

if [ "$#" -gt 0 ]; then
  exec "$@"
fi

echo "Starting Maraithon..."
exec /app/bin/maraithon start
