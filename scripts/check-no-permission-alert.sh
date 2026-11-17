#!/bin/sh
# Guard: the plugin never speaks for permission dialogs.
#
# A Notification hook once said "<folder> session: Claude needs your permission to use <tool>" for every pending
# dialog. It was wrong for questions and plans, noisy for the rest, and it was removed by hand several times while
# the published plugin still carried it, so every plugin update brought it back. This check fails the build if the
# hook, its script or its sentence reappears anywhere in the plugin.

set -u
cd "$(dirname "$0")/.."

fail=0

if grep -q '"Notification"' hooks/hooks.json; then
  echo "check-no-permission-alert: hooks/hooks.json registers a Notification hook" >&2
  fail=1
fi

if [ -e scripts/permission-alert.sh ]; then
  echo "check-no-permission-alert: scripts/permission-alert.sh is back" >&2
  fail=1
fi

found="$(grep -rIl -e 'needs your permission' -e 'permission_prompt' \
  --exclude-dir=.git --exclude-dir=build --exclude-dir=dist --exclude=check-no-permission-alert.sh . || true)"
if [ -n "$found" ]; then
  echo "check-no-permission-alert: the permission sentence or its hook matcher is in:" >&2
  echo "$found" >&2
  fail=1
fi

[ "$fail" -eq 0 ] && echo "check-no-permission-alert: ok"
exit "$fail"
