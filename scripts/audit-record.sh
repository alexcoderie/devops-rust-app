#!/usr/bin/env bash
# Builds ONE audit-log line (compact JSON) for the GitHub event being processed.
#
#   who     actor, actor_type, is_agent
#   what    event, action, detail, ref, sha, pr, run_url
#   when    ts (UTC)
#   ticket  the issue the work served (null when it cannot be resolved)
#
# Inputs (environment):
#   GITHUB_EVENT_NAME, GITHUB_EVENT_PATH, GITHUB_REPOSITORY   set by GitHub Actions
#   GITHUB_SERVER_URL, GITHUB_RUN_ID                          set by GitHub Actions (for run_url)
#   GH_TOKEN                                                  lets `gh` look up tickets and deploy approvers
#   AUDIT_EVENT_NAME, AUDIT_EVENT_PATH, AUDIT_REPO,
#   AUDIT_RUN_URL, AUDIT_NOW                                  overrides, used by the tests
#
# Nothing from the event payload is ever placed in a shell command: values are
# read with jq and written out with jq, so a hostile PR title, body or branch
# name cannot run code or break the log format.
set -euo pipefail

event_name="${AUDIT_EVENT_NAME:-${GITHUB_EVENT_NAME:-}}"
payload="${AUDIT_EVENT_PATH:-${GITHUB_EVENT_PATH:-}}"
repo="${AUDIT_REPO:-${GITHUB_REPOSITORY:-}}"
run_url="${AUDIT_RUN_URL:-}"
if [ -z "$run_url" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
  run_url="${GITHUB_SERVER_URL:-https://github.com}/${repo}/actions/runs/${GITHUB_RUN_ID}"
fi
now="${AUDIT_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

if [ -z "$event_name" ] || [ -z "$repo" ] || [ ! -r "$payload" ]; then
  echo "audit-record: need an event name, a readable payload file and a repository" >&2
  exit 2
fi

jqp() { jq -r "$1" "$payload"; }
is_number() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
have_gh() { command -v gh >/dev/null 2>&1; }

# First "closes/fixes/resolves #N" (or owner/repo#N) in stdin -> N
ticket_from_text() {
  { grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?):?[[:space:]]+([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)?#[0-9]+' || true; } \
    | head -n 1 | { grep -oE '[0-9]+$' || true; }
}

# Ticket for a pull request: its description first, then GitHub's own issue link.
ticket_from_pr() {
  local pr="$1" body="${2:-}" found="" view=""
  found="$(printf '%s' "$body" | ticket_from_text)"
  if [ -z "$found" ] && is_number "$pr" && have_gh; then
    view="$(gh pr view "$pr" --repo "$repo" --json body,closingIssuesReferences 2>/dev/null || true)"
    if [ -n "$view" ]; then
      found="$(printf '%s' "$view" | jq -r '.closingIssuesReferences[0].number // empty' 2>/dev/null || true)"
      if [ -z "$found" ]; then
        found="$(printf '%s' "$view" | jq -r '.body // ""' 2>/dev/null | ticket_from_text)"
      fi
    fi
  fi
  printf '%s' "$found"
}

# Pull request that introduced a commit (used for pushes and deploys).
pr_for_commit() {
  local sha="$1" found=""
  if [ -n "$sha" ] && have_gh; then
    found="$(gh api "repos/$repo/commits/$sha/pulls" --jq '.[0].number // empty' 2>/dev/null || true)"
  fi
  if is_number "$found"; then printf '%s' "$found"; fi
}

actor="$(jqp '.workflow_run.triggering_actor.login // .workflow_run.actor.login // .sender.login // .pusher.name // "unknown"')"
actor_type="$(jqp '.sender.type // "unknown"')"
action="$(jqp '.action // "pushed"')"

ref="" sha="" pr="" ticket="" detail="{}"

case "$event_name" in
  issues)
    ticket="$(jqp '.issue.number // empty')"
    detail="$(jq -c '{assignee: (.assignee.login // null), state_reason: (.issue.state_reason // null)}' "$payload")"
    ;;
  pull_request | pull_request_target)
    pr="$(jqp '.pull_request.number // empty')"
    ref="$(jqp '.pull_request.head.ref // empty')"
    sha="$(jqp '.pull_request.head.sha // empty')"
    ticket="$(ticket_from_pr "$pr" "$(jqp '.pull_request.body // ""')")"
    detail="$(jq -c '{pr_author: (.pull_request.user.login // null), base: (.pull_request.base.ref // null), draft: (.pull_request.draft // false), merged: (.pull_request.merged // false), merged_by: (.pull_request.merged_by.login // null)}' "$payload")"
    ;;
  workflow_run)
    sha="$(jqp '.workflow_run.head_sha // empty')"
    ref="$(jqp '.workflow_run.head_branch // empty')"
    pr="$(jqp '.workflow_run.pull_requests[0].number // empty')"
    if [ -z "$pr" ]; then pr="$(pr_for_commit "$sha")"; fi
    if [ -n "$pr" ]; then ticket="$(ticket_from_pr "$pr" "")"; fi
    run_id="$(jqp '.workflow_run.id // empty')"
    approvers="[]"
    # A push-triggered run (the deploy) waits for a human in the `prod` environment:
    # record who approved it.
    if [ "$(jqp '.workflow_run.event // ""')" = "push" ] && is_number "$run_id" && have_gh; then
      approvers="$(gh api "repos/$repo/actions/runs/$run_id/approvals" \
        --jq '[.[] | select(.state == "approved") | .user.login]' 2>/dev/null || echo '[]')"
      printf '%s' "$approvers" | jq -e 'type == "array"' >/dev/null 2>&1 || approvers="[]"
    fi
    detail="$(jq -c --argjson approvers "$approvers" \
      '{workflow: .workflow_run.name, conclusion: .workflow_run.conclusion, run_id: .workflow_run.id, run_attempt: .workflow_run.run_attempt, run_event: .workflow_run.event, approvers: $approvers}' "$payload")"
    ;;
  push)
    sha="$(jqp '.after // empty')"
    ref="$(jqp '.ref // empty')"
    pr="$(pr_for_commit "$sha")"
    if [ -n "$pr" ]; then ticket="$(ticket_from_pr "$pr" "")"; fi
    detail="$(jq -c '{forced: (.forced // false), commits: ((.commits // []) | length), pusher: (.pusher.name // null)}' "$payload")"
    ;;
  *)
    # Unknown event types are still recorded, so nothing is ever silent.
    ;;
esac

is_number "$ticket" || ticket=""
is_number "$pr" || pr=""

jq -cn \
  --arg ts "$now" --arg event "$event_name" --arg action "$action" \
  --arg actor "$actor" --arg actor_type "$actor_type" --arg repo "$repo" \
  --arg ref "$ref" --arg sha "$sha" --arg pr "$pr" --arg ticket "$ticket" \
  --arg run_url "$run_url" --argjson detail "$detail" '
  {
    ts: $ts,
    event: $event,
    action: $action,
    actor: $actor,
    actor_type: $actor_type,
    is_agent: ($actor | ascii_downcase | test("copilot")),
    repo: $repo,
    ticket: (if $ticket == "" then null else ($ticket | tonumber) end),
    pr: (if $pr == "" then null else ($pr | tonumber) end),
    ref: (if $ref == "" then null else $ref[0:200] end),
    sha: (if $sha == "" then null else $sha end),
    run_url: (if $run_url == "" then null else $run_url end),
    detail: $detail
  }'
