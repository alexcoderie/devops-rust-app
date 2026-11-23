#!/usr/bin/env bash
# Appends ONE line to audit/YYYY-MM.jsonl on the `audit-log` branch and pushes it.
#
#   scripts/audit-append.sh '<json line>'
#
# Run inside a git checkout whose remote accepts pushes (in Actions: actions/checkout
# with persisted credentials). The commit is built with git plumbing, so the working
# tree, the index and the current branch are never touched.
#
# Parallel writers are safe. The push is a plain fast-forward (never forced); when
# another writer wins the race, the whole fetch -> append -> push is repeated on top of
# the new tip, so no line is lost or written twice.
#
# Environment (all optional): AUDIT_REMOTE (origin), AUDIT_BRANCH (audit-log),
# AUDIT_MAX_TRIES (8), AUDIT_RETRY_SLEEP (seconds between tries, default 1-4 random).
set -euo pipefail

line="${1:-}"
if [ -z "$line" ]; then
  echo "usage: audit-append.sh '<json line>'" >&2
  exit 2
fi
if ! printf '%s' "$line" | jq -e 'type == "object" and (.ts | type == "string")' >/dev/null 2>&1; then
  echo "audit-append: not a valid audit record (needs a JSON object with a ts field)" >&2
  exit 2
fi
line="$(printf '%s' "$line" | jq -c .)"

remote="${AUDIT_REMOTE:-origin}"
branch="${AUDIT_BRANCH:-audit-log}"
max_tries="${AUDIT_MAX_TRIES:-8}"

month="$(printf '%s' "$line" | jq -r '.ts[0:7]')"
if ! [[ "$month" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
  echo "audit-append: ts must start with YYYY-MM" >&2
  exit 2
fi
file="audit/$month.jsonl"

export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-github-actions[bot]}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$GIT_AUTHOR_NAME}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$GIT_AUTHOR_EMAIL}"

tmpref="refs/audit-tmp/$branch"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
  git update-ref -d "$tmpref" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# One attempt. Every step is checked by hand because `set -e` is off inside `until`.
try_once() {
  local rc=0 parent="" blob="" tree="" commit="" msg=""

  git ls-remote --exit-code --heads "$remote" "refs/heads/$branch" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0)
      git fetch --quiet --no-tags --depth=1 "$remote" "+refs/heads/$branch:$tmpref" || return 1
      parent="$(git rev-parse "$tmpref")" || return 1
      ;;
    2) parent="" ;; # the branch does not exist yet: this line becomes its first commit
    *) return 1 ;;  # network or permission problem
  esac

  rm -f "$tmp/index"
  : >"$tmp/new"
  if [ -n "$parent" ]; then
    GIT_INDEX_FILE="$tmp/index" git read-tree "$parent" || return 1
    git cat-file -p "$parent:$file" >"$tmp/new" 2>/dev/null || : >"$tmp/new"
  fi
  # Old content must end in a newline before the new line is added.
  if [ -s "$tmp/new" ] && [ -n "$(tail -c 1 "$tmp/new")" ]; then printf '\n' >>"$tmp/new"; fi
  printf '%s\n' "$line" >>"$tmp/new"

  blob="$(git hash-object -w "$tmp/new")" || return 1
  GIT_INDEX_FILE="$tmp/index" git update-index --add --cacheinfo "100644,$blob,$file" || return 1
  tree="$(GIT_INDEX_FILE="$tmp/index" git write-tree)" || return 1
  msg="$(printf '%s' "$line" | jq -r '"audit: \(.event)/\(.action) by \(.actor), ticket \(.ticket // "none")"')" || return 1

  if [ -n "$parent" ]; then
    commit="$(git commit-tree "$tree" -p "$parent" -m "$msg")" || return 1
  else
    commit="$(git commit-tree "$tree" -m "$msg")" || return 1
  fi

  # No --force: if the branch moved in the meantime this is rejected and we retry.
  git push --quiet "$remote" "$commit:refs/heads/$branch" || return 1
}

attempt=1
until try_once; do
  if [ "$attempt" -ge "$max_tries" ]; then
    echo "audit-append: giving up after $attempt attempts, the event was NOT recorded" >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep "${AUDIT_RETRY_SLEEP:-$((RANDOM % 4 + 1))}"
done

echo "audit-append: recorded in $branch ($file), attempt $attempt"
