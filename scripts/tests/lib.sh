#!/usr/bin/env bash
# Tiny assertion helpers shared by the *.test.sh files. Source this file.

tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034 # used by the test files that source this one
scripts_dir="$(cd "$tests_dir/.." && pwd)"
passed=0
failed=0

ok() {
  passed=$((passed + 1))
  printf '  ok    %s\n' "$1"
}

bad() {
  failed=$((failed + 1))
  printf '  FAIL  %s\n' "$1"
}

assert_eq() { # actual expected description
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected '$2', got '$1')"; fi
}

assert_contains() { # haystack needle description
  if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing '$2' in: $1)"; fi
}

assert_not_contains() { # haystack needle description
  if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found '$2' in: $1)"; else ok "$3"; fi
}

assert_file_missing() { # path description
  if [ -e "$1" ]; then bad "$2 ($1 exists)"; else ok "$2"; fi
}

section() { printf '\n%s\n' "$1"; }

finish() {
  printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$passed" "$failed"
  [ "$failed" -eq 0 ]
}
