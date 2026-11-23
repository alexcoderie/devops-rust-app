#!/usr/bin/env bash
# Tests for scripts/audit-append.sh and scripts/audit-show.sh against a real git
# remote (a local bare repository that refuses non-fast-forward pushes, like GitHub
# does for protected branches).
set -uo pipefail
# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export AUDIT_RETRY_SLEEP=0

git init -q --bare -b main "$work/remote.git"
git -C "$work/remote.git" config receive.denyNonFastForwards true
git init -q -b main "$work/seed"
git -C "$work/seed" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m seed
git -C "$work/seed" push -q "$work/remote.git" main

clone() { git clone -q "$work/remote.git" "$1" 2>/dev/null; }
line() { # ts actor event action ticket
  jq -cn --arg ts "$1" --arg actor "$2" --arg event "$3" --arg action "$4" --arg ticket "${5:-}" \
    '{ts: $ts, actor: $actor, is_agent: ($actor | test("copilot"; "i")), event: $event, action: $action,
      ticket: (if $ticket == "" then null else ($ticket | tonumber) end), pr: 13, ref: "copilot/x"}'
}
remote_file() { git -C "$work/remote.git" cat-file -p "audit-log:audit/$1.jsonl"; }

repo="$work/w1"
clone "$repo"
cd "$repo" || exit 1
main_before="$(git rev-parse HEAD)"
assert_eq "$(git rev-parse --abbrev-ref HEAD)" "main" "test setup: clone has main checked out"

section "first write creates the audit-log branch"
out="$(bash "$scripts_dir/audit-append.sh" "$(line 2026-11-22T10:00:00Z alexcoderie issues assigned 12)" 2>&1)"
assert_contains "$out" "recorded in audit-log" "reports success"
assert_eq "$(remote_file 2026-11 | wc -l | tr -d ' ')" "1" "one line on the remote"
assert_eq "$(git -C "$work/remote.git" rev-list --count audit-log)" "1" "one commit"

section "second write appends, never rewrites"
bash "$scripts_dir/audit-append.sh" "$(line 2026-11-22T10:05:00Z Copilot pull_request_target opened 12)" >/dev/null
assert_eq "$(remote_file 2026-11 | wc -l | tr -d ' ')" "2" "two lines"
assert_eq "$(remote_file 2026-11 | head -1 | jq -r .actor)" "alexcoderie" "first line unchanged and still first"
assert_eq "$(git -C "$work/remote.git" rev-list --count audit-log)" "2" "history grew by one commit"

section "a new month starts a new file"
bash "$scripts_dir/audit-append.sh" "$(line 2026-12-01T00:00:01Z alexcoderie push pushed 12)" >/dev/null
assert_eq "$(remote_file 2026-12 | wc -l | tr -d ' ')" "1" "december file"
assert_eq "$(remote_file 2026-11 | wc -l | tr -d ' ')" "2" "november untouched"

section "the checkout is left alone"
assert_eq "$(git rev-parse HEAD)" "$main_before" "current branch did not move"
assert_eq "$(git status --porcelain | wc -l | tr -d ' ')" "0" "working tree and index clean"
assert_eq "$(git branch --list audit-log | wc -l | tr -d ' ')" "0" "no local audit-log branch created"
assert_eq "$(git for-each-ref refs/audit-tmp | wc -l | tr -d ' ')" "0" "temporary ref cleaned up"

section "8 writers at once: nothing lost, nothing duplicated"
before="$(remote_file 2026-11 | wc -l | tr -d ' ')"
pids=()
for i in 1 2 3 4 5 6 7 8; do
  c="$work/par$i"
  clone "$c"
  (cd "$c" && AUDIT_RETRY_SLEEP=0 AUDIT_MAX_TRIES=40 bash "$scripts_dir/audit-append.sh" "$(line "2026-11-23T10:00:0${i}Z" "worker$i" issues opened "$i")" >/dev/null 2>&1) &
  pids+=("$!")
done
fail_count=0
for p in "${pids[@]}"; do wait "$p" || fail_count=$((fail_count + 1)); done
assert_eq "$fail_count" "0" "every writer succeeded"
assert_eq "$(remote_file 2026-11 | wc -l | tr -d ' ')" "$((before + 8))" "exactly 8 new lines"
assert_eq "$(remote_file 2026-11 | jq -r '.actor' | grep -c '^worker')" "8" "all 8 workers present"
assert_eq "$(remote_file 2026-11 | jq -r '.actor' | grep '^worker' | sort -u | wc -l | tr -d ' ')" "8" "no duplicates"
assert_eq "$(remote_file 2026-11 | jq -e . >/dev/null 2>&1 && echo valid)" "valid" "every line is still valid JSON"
assert_eq "$(git -C "$work/remote.git" rev-list --merges --count audit-log)" "0" "history is linear (no merges, no force)"

section "8 writers at once on a remote with NO branch protection (a force push would lose lines here)"
git init -q --bare -b main "$work/open.git"
git -C "$work/seed" push -q "$work/open.git" main
pids=()
for i in 1 2 3 4 5 6 7 8; do
  git clone -q "$work/open.git" "$work/open$i" 2>/dev/null
  (cd "$work/open$i" && AUDIT_RETRY_SLEEP=0 AUDIT_MAX_TRIES=40 bash "$scripts_dir/audit-append.sh" "$(line "2026-11-23T11:00:0${i}Z" "open$i" issues opened "$i")" >/dev/null 2>&1) &
  pids+=("$!")
done
fail_count=0
for p in "${pids[@]}"; do wait "$p" || fail_count=$((fail_count + 1)); done
open_lines="$(git -C "$work/open.git" cat-file -p audit-log:audit/2026-11.jsonl | jq -r .actor | grep -c '^open')"
assert_eq "$fail_count" "0" "every writer succeeded"
assert_eq "$open_lines" "8" "all 8 lines survived without server-side protection"

section "a stale writer cannot overwrite newer history"
tip_before="$(git -C "$work/remote.git" rev-parse audit-log)"
bash "$scripts_dir/audit-append.sh" "$(line 2026-11-24T09:00:00Z alexcoderie issues closed 12)" >/dev/null
assert_eq "$(git -C "$work/remote.git" merge-base --is-ancestor "$tip_before" audit-log && echo ancestor)" "ancestor" "old tip is an ancestor of the new tip"

section "invalid input is refused and nothing is pushed"
tip="$(git -C "$work/remote.git" rev-parse audit-log)"
bash "$scripts_dir/audit-append.sh" 'not json' 2>/dev/null
assert_eq "$?" "2" "non-JSON exits 2"
bash "$scripts_dir/audit-append.sh" '{"no":"ts"}' 2>/dev/null
assert_eq "$?" "2" "missing ts exits 2"
bash "$scripts_dir/audit-append.sh" '{"ts":"yesterday"}' 2>/dev/null
assert_eq "$?" "2" "bad ts exits 2"
bash "$scripts_dir/audit-append.sh" 2>/dev/null
assert_eq "$?" "2" "no argument exits 2"
assert_eq "$(git -C "$work/remote.git" rev-parse audit-log)" "$tip" "remote unchanged"

section "a rejected push is an error, not a silent loss"
cat >"$work/remote.git/hooks/pre-receive" <<'HOOK'
#!/bin/sh
echo "remote: rejected for the test" >&2
exit 1
HOOK
chmod +x "$work/remote.git/hooks/pre-receive"
AUDIT_MAX_TRIES=2 bash "$scripts_dir/audit-append.sh" "$(line 2026-11-25T09:00:00Z alexcoderie issues closed 12)" >/dev/null 2>"$work/err.txt"
assert_eq "$?" "1" "exits 1 after the tries are used up"
assert_contains "$(cat "$work/err.txt")" "NOT recorded" "says plainly that the event was not recorded"
rm -f "$work/remote.git/hooks/pre-receive"

section "unreachable remote is an error too"
AUDIT_REMOTE=nowhere AUDIT_MAX_TRIES=1 bash "$scripts_dir/audit-append.sh" "$(line 2026-11-25T09:00:00Z a b c)" >/dev/null 2>&1
assert_eq "$?" "1" "exits 1"

section "audit-show: reading the log back"
shown="$(bash "$scripts_dir/audit-show.sh")"
assert_eq "$(printf '%s\n' "$shown" | wc -l | tr -d ' ')" "12" "all 12 events listed (3 + 8 parallel + 1)"
assert_contains "$shown" "Copilot" "the agent's actions are visible"
only12="$(bash "$scripts_dir/audit-show.sh" --ticket 12)"
assert_eq "$(printf '%s\n' "$only12" | wc -l | tr -d ' ')" "4" "--ticket 12 filters to that ticket"
assert_not_contains "$only12" "worker" "other tickets are excluded"
agent="$(bash "$scripts_dir/audit-show.sh" --agent --json)"
assert_eq "$(printf '%s\n' "$agent" | wc -l | tr -d ' ')" "1" "--agent keeps only the agent's events"
assert_eq "$(bash "$scripts_dir/audit-show.sh" --month 2026-12 | wc -l | tr -d ' ')" "1" "--month filters by month"
bash "$scripts_dir/audit-show.sh" --ticket abc >/dev/null 2>&1
assert_eq "$?" "2" "bad --ticket exits 2"

section "audit-show with no audit-log branch"
clone "$work/fresh"
git init -q --bare "$work/empty.git"
(cd "$work/fresh" && git remote set-url origin "$work/empty.git" && bash "$scripts_dir/audit-show.sh" >/dev/null 2>&1)
assert_eq "$?" "1" "exits 1 with a clear message"

finish
