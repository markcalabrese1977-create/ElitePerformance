#!/bin/bash
# Usage: Tests/compare_failures.sh LOG [LOG...]
# Reads xcodebuild test logs; compares failing tests by set against Tests/known_failures.txt.
#   NEW FAILURES            failed in the logs, not in known_failures.txt
#   KNOWN WITHOUT RESULT    in known_failures.txt, but no pass/fail result in the logs
#                           (skipped, crashed host, or not run)
# Exit status is 1 if there are any new failures.
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: $0 LOG [LOG...]" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# "Test Case '-[Module.Class method]' failed|passed" -> "Class method"
# Accepts both log formats:
#   Test case 'Class.method()' failed on '...'            (Xcode 16+ / xcodebuild test)
#   Test Case '-[Module.Class method]' failed (0.1 sec)   (classic XCTest)
extract() {
  local verb="$1"; shift
  { grep -hE "^Test case '[^ ]+\(\)' $verb " "$@" \
      | sed -E "s/^Test case '([^.]+)\.([^(]+)\(\)'.*/\1 \2/"
    grep -hE "^Test Case '-\[[^ ]+ [^]]+\]' $verb " "$@" \
      | sed -E "s/^Test Case '-\[([^ .]+\.)?([^ ]+) ([^]]+)\]'.*/\2 \3/"
  } | sort -u
}
extract failed "$@" > "$tmp/failed" || true
extract passed "$@" > "$tmp/passed" || true
sort "$tmp/failed" "$tmp/passed" | sort -u > "$tmp/ran"
grep -vE '^\s*(#|$)' "$here/known_failures.txt" | sed -E 's/[[:space:]]*#.*$//' | sort -u > "$tmp/known"

comm -23 "$tmp/failed" "$tmp/known" > "$tmp/new"
comm -13 "$tmp/ran" "$tmp/known" > "$tmp/noresult"

echo "== failed: $(wc -l < "$tmp/failed" | tr -d ' ')  passed: $(wc -l < "$tmp/passed" | tr -d ' ')  known: $(wc -l < "$tmp/known" | tr -d ' ')"
echo "== NEW FAILURES ($(wc -l < "$tmp/new" | tr -d ' '))"; cat "$tmp/new"
echo "== KNOWN WITHOUT RESULT ($(wc -l < "$tmp/noresult" | tr -d ' '))"; cat "$tmp/noresult"
[ ! -s "$tmp/new" ]
