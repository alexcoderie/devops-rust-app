#!/usr/bin/env bash
# Tests for scripts/kill-switch.sh against a simulated GitHub (scripts/tests/bin/gh).
# The important property: it must never report "ENGAGED" unless it has checked.
set -uo pipefail
# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PATH="$tests_dir/bin:$PATH"
export KILL_SWITCH_RETRY_SLEEP=0
n=0

# fresh: a new simulated GitHub with Actions on, 33 active runs and a few issues
fresh() {
  n=$((n + 1))
  export GH_STUB_DIR="$work/gh$n"
  export KILL_SWITCH_STATE_DIR="$work/state$n"
  unset GH_STUB_UNAUTH GH_STUB_LIST_FAIL
  mkdir -p "$GH_STUB_DIR"
  : >"$GH_STUB_DIR/calls.log"
  echo true >"$GH_STUB_DIR/actions_enabled"
  echo selected >"$GH_STUB_DIR/allowed_actions"
  { seq 101 130; } >"$GH_STUB_DIR/runs_queued"
  printf '131\n132\n133\n' >"$GH_STUB_DIR/runs_in_progress"
  cat >"$GH_STUB_DIR/issues.json" <<'JSON'
[
  {"number": 7,  "assignees": [{"login": "Copilot"}, {"login": "alexcoderie"}]},
  {"number": 8,  "assignees": [{"login": "alexcoderie"}]},
  {"number": 9,  "assignees": [{"login": "Copilot"}]},
  {"number": 10, "pull_request": {"url": "x"}, "assignees": [{"login": "Copilot"}]}
]
JSON
}
ks() { bash "$scripts_dir/kill-switch.sh" "$@" 2>&1; }
calls() { cat "$GH_STUB_DIR/calls.log"; }
assignees() { jq -r --argjson n "$1" '.[] | select(.number == $n) | [.assignees[].login] | join(",")' "$GH_STUB_DIR/issues.json"; }
active_runs() { cat "$GH_STUB_DIR"/runs_* 2>/dev/null | grep -c . || true; }

section "engage: stops runs, disables Actions, unassigns Copilot, records it"
fresh
out="$(ks --repo octo/demo)"
rc=$?
assert_eq "$rc" "0" "exit 0"
assert_contains "$out" "KILL SWITCH ENGAGED" "says engaged"
assert_eq "$(cat "$GH_STUB_DIR/actions_enabled")" "false" "Actions disabled"
assert_eq "$(active_runs)" "0" "all 33 runs cancelled (30 queued + 3 running)"
assert_eq "$(assignees 7)" "alexcoderie" "Copilot removed from #7, the human stays"
assert_eq "$(assignees 8)" "alexcoderie" "#8 untouched"
assert_eq "$(assignees 9)" "" "Copilot removed from #9"
assert_eq "$(assignees 10)" "Copilot" "a pull request is left alone"
assert_eq "$(jq -r .allowed_actions "$KILL_SWITCH_STATE_DIR/octo_demo.actions.json")" "selected" "previous settings saved for --resume"
assert_contains "$(calls)" "issue create" "a record issue was opened"
assert_contains "$out" "Repository access" "reminds you of the manual Copilot setting"
elapsed="$(printf '%s' "$out" | sed -n 's/.*ENGAGED in \([0-9]*\)s.*/\1/p')"
assert_eq "$([ "${elapsed:-999}" -le 60 ] && echo within-a-minute)" "within-a-minute" "reports elapsed time (${elapsed}s)"
first_cancel="$(calls | grep -n 'actions/runs/.*/cancel' | head -1 | cut -d: -f1)"
disable="$(calls | grep -n -- '-X PUT .*actions/permissions -F enabled=false' | head -1 | cut -d: -f1)"
assert_eq "$([ "$first_cancel" -lt "$disable" ] && echo yes)" "yes" "runs are cancelled before Actions is switched off"
# The second sweep finds nothing left, so there is no cancel to send, but it must LOOK again.
relisted="$(calls | tail -n +"$((disable + 1))" | grep -c 'actions/runs?status=')"
assert_eq "$([ "$relisted" -ge 5 ] && echo yes)" "yes" "after switching Actions off it looks for stragglers again ($relisted listings)"

section "dry run changes nothing"
fresh
out="$(ks --repo octo/demo --dry-run)"
rc=$?
assert_eq "$rc" "0" "exit 0"
assert_contains "$out" "DRY RUN" "labelled as a dry run"
assert_eq "$(cat "$GH_STUB_DIR/actions_enabled")" "true" "Actions still on"
assert_eq "$(active_runs)" "33" "runs still there"
assert_eq "$(assignees 9)" "Copilot" "assignments untouched"
assert_not_contains "$(calls)" "-X POST" "no cancel was sent"
assert_not_contains "$(calls)" "-X PUT" "no settings change was sent"
assert_not_contains "$(calls)" "-X DELETE" "no unassign was sent"
assert_not_contains "$(calls)" "issue create" "no record issue"
assert_file_missing "$KILL_SWITCH_STATE_DIR" "no state written"

section "--no-record skips the issue"
fresh
ks --repo octo/demo --no-record >/dev/null
assert_not_contains "$(calls)" "issue create" "no record issue"

section "engaging twice keeps the ORIGINAL settings"
fresh
ks --repo octo/demo >/dev/null
out="$(ks --repo octo/demo)"
rc=$?
assert_eq "$rc" "0" "second run also succeeds"
assert_contains "$out" "already off" "notices Actions is already off"
assert_eq "$(jq -r .allowed_actions "$KILL_SWITCH_STATE_DIR/octo_demo.actions.json")" "selected" "saved settings not overwritten by the disabled state"

section "resume restores Actions exactly"
fresh
ks --repo octo/demo >/dev/null
out="$(ks --repo octo/demo --resume)"
rc=$?
assert_eq "$rc" "0" "exit 0"
assert_eq "$(cat "$GH_STUB_DIR/actions_enabled")" "true" "Actions on again"
assert_eq "$(cat "$GH_STUB_DIR/allowed_actions")" "selected" "original allowed-actions policy restored"
assert_eq "$(assignees 9)" "" "Copilot is NOT silently re-assigned"
assert_file_missing "$KILL_SWITCH_STATE_DIR/octo_demo.actions.json" "saved settings consumed"
assert_contains "$out" "RELEASED" "says released"

section "resume with no saved settings warns instead of guessing silently"
fresh
echo false >"$GH_STUB_DIR/actions_enabled"
out="$(ks --repo octo/demo --resume)"
assert_contains "$out" "WARNING" "warns"
assert_eq "$(cat "$GH_STUB_DIR/actions_enabled")" "true" "Actions on"

section "a run that ignores cancel is force-cancelled"
fresh
touch "$GH_STUB_DIR/stuck_131"
out="$(ks --repo octo/demo)"
rc=$?
assert_eq "$rc" "0" "still engaged"
assert_contains "$out" "force-cancelling" "escalated"
assert_eq "$(active_runs)" "0" "nothing left running"

section "a run that cannot be killed: refuse to say ENGAGED"
fresh
touch "$GH_STUB_DIR/unkillable_131"
out="$(ks --repo octo/demo)"
rc=$?
assert_eq "$rc" "1" "exit 1"
assert_contains "$out" "NOT FULLY ENGAGED" "says so"
assert_contains "$out" "STILL RUNNING" "names the problem"
assert_not_contains "$out" "KILL SWITCH ENGAGED" "never claims success"
assert_not_contains "$(calls)" "issue create" "no 'engaged' record is written"
assert_contains "$out" "Repository access" "still tells you the manual step"

section "cannot list runs after Actions is off: refuse to say ENGAGED"
fresh
export GH_STUB_LIST_FAIL=1
out="$(ks --repo octo/demo)"
rc=$?
assert_eq "$rc" "1" "exit 1"
assert_contains "$out" "cannot confirm" "explains it cannot verify"
assert_not_contains "$out" "KILL SWITCH ENGAGED" "never claims success"

section "Copilot cannot be unassigned: refuse to say ENGAGED"
fresh
touch "$GH_STUB_DIR/reject_login_Copilot"
out="$(ks --repo octo/demo)"
rc=$?
assert_eq "$rc" "1" "exit 1"
assert_contains "$out" "still assigned" "the final check catches it"
assert_not_contains "$out" "KILL SWITCH ENGAGED" "never claims success"
assert_contains "$(calls)" "copilot-swe-agent[bot]" "tried the other spelling of the agent's login"

section "setup problems"
fresh
export GH_STUB_UNAUTH=1
out="$(ks --repo octo/demo)"
rc=$?
assert_eq "$rc" "2" "not logged in: exit 2"
assert_contains "$out" "gh auth login" "tells you what to do"
assert_eq "$(cat "$GH_STUB_DIR/actions_enabled")" "true" "nothing changed"
fresh
ks --repo 'a b' >/dev/null
assert_eq "$?" "2" "bad repo name rejected"
ks --repo >/dev/null
assert_eq "$?" "2" "--repo without a value rejected"
ks --frobnicate >/dev/null
assert_eq "$?" "2" "unknown option rejected"
out="$(ks --help)"
assert_eq "$?" "0" "--help works"
assert_contains "$out" "KILL SWITCH" "--help prints the header"

section "repository is detected when --repo is not given"
fresh
export GH_STUB_REPO=octo/demo
out="$(ks)"
rc=$?
assert_eq "$rc" "0" "exit 0"
assert_contains "$(calls)" "repos/octo/demo/actions/permissions" "used the detected repository"

finish
