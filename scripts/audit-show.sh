#!/usr/bin/env bash
# Prints the audit log in a readable form. Run from a checkout of the repository.
#
#   scripts/audit-show.sh                  everything, one line per event
#   scripts/audit-show.sh --ticket 12      only what served ticket #12
#   scripts/audit-show.sh --agent          only what the agent did
#   scripts/audit-show.sh --month 2026-11  only one month
#   scripts/audit-show.sh --json           raw JSON lines (pipe into jq)
#
# Columns: when, who, what, ticket, pull request, branch
set -euo pipefail

remote="${AUDIT_REMOTE:-origin}"
branch="${AUDIT_BRANCH:-audit-log}"
ticket="" agent=0 month="" json=0

while [ $# -gt 0 ]; do
  case "$1" in
    --ticket) ticket="${2:-}"; shift 2 ;;
    --month) month="${2:-}"; shift 2 ;;
    --agent) agent=1; shift ;;
    --json) json=1; shift ;;
    -h | --help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
if [ -n "$ticket" ] && ! [[ "$ticket" =~ ^[0-9]+$ ]]; then echo "--ticket needs a number" >&2; exit 2; fi
if [ -n "$month" ] && ! [[ "$month" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then echo "--month needs YYYY-MM" >&2; exit 2; fi

tmpref="refs/audit-tmp/$branch"
trap 'git update-ref -d "$tmpref" >/dev/null 2>&1 || true' EXIT
git fetch --quiet --no-tags --depth=1 "$remote" "+refs/heads/$branch:$tmpref" \
  || { echo "no $branch branch on $remote yet: nothing has been recorded" >&2; exit 1; }

filter='select(true)'
if [ -n "$ticket" ]; then filter="$filter | select(.ticket == $ticket)"; fi
if [ "$agent" -eq 1 ]; then filter="$filter | select(.is_agent)"; fi

while IFS= read -r path; do
  if [ -n "$month" ] && [ "$path" != "audit/$month.jsonl" ]; then continue; fi
  git cat-file -p "$tmpref:$path"
done < <(git ls-tree --name-only "$tmpref" audit/ | sort) \
  | if [ "$json" -eq 1 ]; then
      jq -c "$filter"
    else
      jq -r "$filter | [.ts, .actor, (.event + \"/\" + .action), (if .ticket then \"#\" + (.ticket|tostring) else \"-\" end), (if .pr then \"PR\" + (.pr|tostring) else \"-\" end), (.ref // \"-\")] | @tsv"
    fi
