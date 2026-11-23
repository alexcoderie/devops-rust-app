#!/usr/bin/env bash
# Runs every scripts/tests/*.test.sh. Exit status is non-zero if any file fails.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status=0
for t in "$here"/*.test.sh; do
  printf '\n=== %s ===\n' "$(basename "$t")"
  bash "$t" || status=1
done

if [ "$status" -eq 0 ]; then printf '\nAll script tests passed.\n'; else printf '\nSCRIPT TESTS FAILED.\n'; fi
exit "$status"
