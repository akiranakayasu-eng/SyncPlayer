#!/bin/sh
# The iOS app uses copies of the Mac files that define the sync protocol. They must stay identical.
cd "$(dirname "$0")/.." || exit 1
rc=0
for f in Protocol ClockSync Net; do
  diff -q "Sources/SyncPlayer/$f.swift" "ios/SyncFollower/Shared/$f.swift" >/dev/null || { echo "DIFFERS: $f.swift"; rc=1; }
done
[ $rc = 0 ] && echo "shared files match"
exit $rc
