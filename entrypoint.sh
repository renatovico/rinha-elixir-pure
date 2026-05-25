#!/bin/sh
set -e

# Remove stale ready file
rm -f /tmp/ready

exec /app/bin/rinha start
