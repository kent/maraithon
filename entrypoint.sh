#!/bin/sh
set -e

echo "Starting Maraithon..."
echo "Running database migrations..."
/app/bin/maraithon eval "Maraithon.Release.migrate" || echo "Migration failed or already applied"
echo "Starting server..."
exec /app/bin/maraithon start
