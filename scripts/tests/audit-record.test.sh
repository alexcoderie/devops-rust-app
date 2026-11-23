#!/usr/bin/env bash
# Tests for scripts/audit-record.sh: one valid JSON line per event, with the right
# who / what / when / ticket, and no way for hostile payload text to run code.
set -uo pipefail
# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GH_STUB_DIR="$work/gh"
mkdir -p "$GH_STUB_DIR"
export PATH="$tests_dir/bin:$PATH"
fx="$tests_dir/fixtures"

SHA_MAIN=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
cp "$fx/gh-pr_13.json" "$GH_STUB_DIR/pr_13.json"
cp "$fx/gh-pr_14.json" "$GH_STUB_DIR/pr_14.json"
cp "$fx/gh-approvals_777.json" "$GH_STUB_DIR/approvals_777.json"
cp "$fx/gh-commit_pulls_main.json" "$GH_STUB_DIR/commit_pulls_$SHA_MAIN.json"

export AUDIT_REPO=octo/demo
export AUDIT_NOW=2026-11-22T10:00:00Z
export AUDIT_RUN_URL=https://github.com/octo/demo/actions/runs/1

# record <event> <fixture-file>  -> prints the audit line
record() {
  AUDIT_EVENT_NAME="$1" AUDIT_EVENT_PATH="$2" bash "$scripts_dir/audit-record.sh"
}
field() { printf '%s' "$1" | jq -r "$2"; }

section "issue assigned (a human hands a ticket to the agent)"
out="$(record issues "$fx/issues-assigned.json")"
assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1" "exactly one line"
assert_eq "$(field "$out" .actor)" "alexcoderie" "who: the human who assigned"
assert_eq "$(field "$out" .is_agent)" "false" "the human is not flagged as agent"
assert_eq "$(field "$out" .ticket)" "12" "ticket is the issue number"
assert_eq "$(field "$out" .detail.assignee)" "Copilot" "what: assigned to Copilot"
assert_eq "$(field "$out" .ts)" "2026-11-22T10:00:00Z" "when"
assert_eq "$(field "$out" .run_url)" "https://github.com/octo/demo/actions/runs/1" "run url"

section "pull request opened by the agent (ticket from the description)"
out="$(record pull_request_target "$fx/pr-opened-copilot.json")"
assert_eq "$(field "$out" .actor)" "Copilot" "who: Copilot"
assert_eq "$(field "$out" .is_agent)" "true" "flagged as agent"
assert_eq "$(field "$out" .ticket)" "12" "ticket from 'Fixes #12'"
assert_eq "$(field "$out" .pr)" "13" "pr number"
assert_eq "$(field "$out" .ref)" "copilot/ticket-list-products" "branch"
assert_eq "$(field "$out" .detail.draft)" "true" "draft flag"

section "pull request with no link in the description (ticket from GitHub's issue link)"
out="$(record pull_request_target "$fx/pr-opened-nolink.json")"
assert_eq "$(field "$out" .ticket)" "12" "ticket from closingIssuesReferences"

section "pull request with no link anywhere"
rm -f "$GH_STUB_DIR/pr_14.json"
out="$(record pull_request_target "$fx/pr-opened-nolink.json")"
assert_eq "$(field "$out" .ticket)" "null" "ticket is null, not invented"
cp "$fx/gh-pr_14.json" "$GH_STUB_DIR/pr_14.json"

section "pull request merged by a human"
out="$(record pull_request_target "$fx/pr-closed-merged.json")"
assert_eq "$(field "$out" .actor)" "alexcoderie" "who: the human who merged"
assert_eq "$(field "$out" .action)" "closed" "action"
assert_eq "$(field "$out" .detail.merged)" "true" "merged"
assert_eq "$(field "$out" .detail.merged_by)" "alexcoderie" "merged_by"
assert_eq "$(field "$out" .detail.pr_author)" "Copilot" "author of the work stays visible"
assert_eq "$(field "$out" .ticket)" "12" "ticket from 'Closes #12'"

section "CI run finished on the agent's pull request"
out="$(record workflow_run "$fx/workflow-run-ci.json")"
assert_eq "$(field "$out" .detail.workflow)" "Build and Test" "workflow name"
assert_eq "$(field "$out" .detail.conclusion)" "failure" "conclusion"
assert_eq "$(field "$out" .pr)" "13" "pr from the run"
assert_eq "$(field "$out" .ticket)" "12" "ticket via the pr"
assert_eq "$(field "$out" .detail.approvers)" "[]" "no approvers for a CI run"
assert_not_contains "$(cat "$GH_STUB_DIR/calls.log")" "approvals" "approvals only fetched for deploys"

section "deploy finished (who approved it, which ticket it shipped)"
out="$(record workflow_run "$fx/workflow-run-deploy.json")"
assert_eq "$(field "$out" .detail.workflow)" "Fly Deploy" "workflow name"
assert_eq "$(field "$out" '.detail.approvers | join(",")')" "alexcoderie" "only 'approved' reviews count"
assert_eq "$(field "$out" .pr)" "13" "pr found from the commit"
assert_eq "$(field "$out" .ticket)" "12" "ticket found through the pr"
assert_eq "$(field "$out" .sha)" "$SHA_MAIN" "deployed commit"

section "push to main"
out="$(record push "$fx/push-main.json")"
assert_eq "$(field "$out" .action)" "pushed" "action"
assert_eq "$(field "$out" .ref)" "refs/heads/main" "ref"
assert_eq "$(field "$out" .detail.commits)" "2" "commit count"
assert_eq "$(field "$out" .ticket)" "12" "ticket via the merged pr"

section "unknown event is still recorded"
out="$(record deployment "$fx/push-main.json")"
assert_eq "$(field "$out" .event)" "deployment" "event kept"
assert_eq "$(printf '%s' "$out" | jq -e . >/dev/null 2>&1 && echo valid)" "valid" "valid JSON"

section "gh unavailable: the line is still written, ticket from the description only"
out="$(PATH="$(dirname "$(command -v jq)"):/usr/bin:/bin" record pull_request_target "$fx/pr-opened-nolink.json")"
assert_eq "$(field "$out" .ticket)" "null" "no crash, ticket null"

section "hostile payload cannot run code or break the log"
canary="$work/pwned"
jq -n --arg canary "$canary" '{
  action: "opened",
  pull_request: {
    number: 15, draft: false, merged: false, user: {login: "x\"; touch \($canary); \""},
    body: "$(touch \($canary)) `touch \($canary)` Fixes #99\nsecond line",
    head: {ref: ("a\"; touch \($canary); echo \"" + ("z" * 300)), sha: "cccc"},
    base: {ref: "main"}
  },
  sender: {login: "evil\nCopilot", type: "User"}
}' >"$work/hostile.json"
out="$(record pull_request_target "$work/hostile.json" 2>/dev/null)"
assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1" "still exactly one line (newlines escaped)"
assert_eq "$(printf '%s' "$out" | jq -e . >/dev/null 2>&1 && echo valid)" "valid" "still valid JSON"
assert_file_missing "$canary" "no command from the payload was executed"
assert_eq "$(field "$out" '.ref | length')" "200" "branch name truncated to 200 characters"
assert_eq "$(field "$out" .ticket)" "99" "ticket still parsed from the text"

section "bad input"
AUDIT_EVENT_NAME=issues AUDIT_EVENT_PATH="$work/missing.json" bash "$scripts_dir/audit-record.sh" 2>/dev/null
assert_eq "$?" "2" "missing payload file exits 2"

finish
