#!/bin/sh
set -e

# Remove stale socket file if it exists
if [ -n "$SOCKET_PATH" ] && [ -e "$SOCKET_PATH" ]; then
  rm -f "$SOCKET_PATH"
fi

# Remove stale ready file
rm -f /tmp/ready

# Start the app in background, then chmod the socket once it appears so
# nginx (running as the unprivileged `nginx` user in the sibling container)
# can connect.  The shared tmpfs volume preserves file modes across the
# bind mount.
if [ -n "$SOCKET_PATH" ]; then
  (
    while [ ! -S "$SOCKET_PATH" ]; do sleep 0.1; done
    chmod 0777 "$SOCKET_PATH"
  ) &
fi

exec /app/bin/rinha start
