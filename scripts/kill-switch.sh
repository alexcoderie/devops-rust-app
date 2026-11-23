#!/usr/bin/env bash
# KILL SWITCH: one command that stops the agents. Target: under 60 seconds.
#
# Run it from YOUR computer, logged in as the repository owner (`gh auth login`).
# It is deliberately not a workflow: a kill switch that runs on the system it is
# shutting down could be stopped by the very thing it is meant to stop.
#
#   scripts/kill-switch.sh                 engage (repo is taken from the current folder)
#   scripts/kill-switch.sh --repo o/name   engage a specific repository
#   scripts/kill-switch.sh --dry-run       show what it would do, change nothing (rehearse with this)
#   scripts/kill-switch.sh --no-record     do not open a "kill switch used" issue
#   scripts/kill-switch.sh --resume        undo it: turn GitHub Actions back on
#
# What engaging does, in order:
#   1. saves the current Actions permissions (so --resume restores them exactly)
#   2. cancels every queued and running workflow run (an agent session is one)
#   3. disables GitHub Actions for the repository (nothing new can start)
#   4. cancels again, to catch anything that started in between
#   5. removes Copilot from every open issue it is assigned to
#   6. checks that nothing is still running, force-cancelling stragglers
#   7. prints how long it took and opens an issue as a permanent record
#
# What it cannot do: GitHub documents no API for the Copilot "Repository access"
# setting, so the last line of output reminds you to switch it off by hand
# (Copilot settings -> Cloud agent -> Repository access -> No repositories).
#
# Exit status: 0 engaged, 1 not fully engaged (read the output), 2 usage/setup error.
set -euo pipefail

repo="" dry=0 record=1 mode=engage
retry_sleep="${KILL_SWITCH_RETRY_SLEEP:-2}"
state_dir="${KILL_SWITCH_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/software-factory}"
start=$SECONDS

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { echo "kill-switch: $*" >&2; exit 2; }
log() { printf '[%3ss] %s\n' "$((SECONDS - start))" "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || die "--repo needs owner/name"; repo="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    --no-record) record=0; shift ;;
    --resume) mode=resume; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

command -v gh >/dev/null 2>&1 || die "the GitHub CLI (gh) is not installed"
command -v jq >/dev/null 2>&1 || die "jq is not installed"
gh auth status >/dev/null 2>&1 || die "not logged in: run 'gh auth login' first"

if [ -z "$repo" ]; then
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" \
    || die "could not tell which repository: run this inside the repository folder or pass --repo owner/name"
fi
[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "repository must look like owner/name, got '$repo'"

state_file="$state_dir/${repo//\//_}.actions.json"

# Runs a command that CHANGES something on GitHub, or only prints it under --dry-run.
mutate() {
  if [ "$dry" -eq 1 ]; then
    echo "DRY RUN, would run: $*" >&2
    return 0
  fi
  "$@"
}

actions_enabled() { gh api "repos/$repo/actions/permissions" --jq '.enabled' 2>/dev/null || echo unknown; }

record_issue() { # title, body
  if [ "$record" -eq 0 ] || [ "$dry" -eq 1 ]; then return 0; fi
  if gh issue create --repo "$repo" --title "$1" --body "$2" >/dev/null 2>&1; then
    log "recorded as an issue (permanent record)"
  else
    log "could not open the record issue (not fatal)"
  fi
}

# ---------------------------------------------------------------- resume
if [ "$mode" = resume ]; then
  allowed="all"
  if [ -f "$state_file" ]; then
    allowed="$(jq -r '.allowed_actions // "all"' "$state_file")"
  else
    log "WARNING: no saved settings for $repo, restoring 'all actions'. Review Settings -> Actions afterwards."
  fi
  log "Turning GitHub Actions back on for $repo (allowed actions: $allowed)"
  mutate gh api -X PUT "repos/$repo/actions/permissions" -F enabled=true -f "allowed_actions=$allowed" --silent
  if [ "$dry" -eq 0 ]; then
    [ "$(actions_enabled)" = "true" ] || { log "Actions is still not enabled, check Settings -> Actions"; exit 1; }
    rm -f "$state_file"
  fi
  record_issue "Kill switch released ($(date -u +%Y-%m-%dT%H:%M:%SZ))" \
    "GitHub Actions was turned back on for $repo using scripts/kill-switch.sh --resume. Copilot was not re-assigned to anything, and the Copilot cloud agent setting was not changed."
  log "RELEASED. Actions is on again. Copilot is not re-assigned to any issue."
  echo "If you set Copilot -> Cloud agent -> Repository access to 'No repositories', set it back by hand."
  exit 0
fi

# ---------------------------------------------------------------- engage
label=""
if [ "$dry" -eq 1 ]; then label=" (DRY RUN)"; fi
echo "================ KILL SWITCH${label} ================"
log "Repository: $repo"

# 1. Remember today's settings so --resume can put them back exactly.
if [ "$(actions_enabled)" = "true" ]; then
  if [ "$dry" -eq 0 ]; then
    mkdir -p "$state_dir"
    gh api "repos/$repo/actions/permissions" >"$state_file"
  fi
  log "saved current Actions settings"
else
  log "Actions is already off (keeping the settings saved earlier)"
fi

statuses=(queued in_progress waiting pending requested)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Ids of runs that are queued or running. If GitHub cannot be asked, that is NOT the
# same as "nothing is running": a marker file records the failure so the final check
# refuses to report success.
active_run_ids() {
  local s out
  for s in "${statuses[@]}"; do
    if out="$(gh api "repos/$repo/actions/runs?status=$s&per_page=100" --jq '.workflow_runs[].id' 2>/dev/null)"; then
      if [ -n "$out" ]; then printf '%s\n' "$out"; fi
    else
      : >"$tmp/list_failed"
    fi
  done | sort -u
}

# cancel_runs <cancel|force-cancel>: sets $cancel_count
cancel_runs() {
  local ids
  ids="$(active_run_ids)"
  cancel_count=0
  [ -n "$ids" ] || return 0
  cancel_count="$(printf '%s\n' "$ids" | wc -l | tr -d ' ')"
  if [ "$dry" -eq 1 ]; then
    printf '%s\n' "$ids" | while read -r id; do echo "DRY RUN, would $1 run $id" >&2; done
    return 0
  fi
  # eight at a time; a run that already finished answers 409, which is fine
  printf '%s\n' "$ids" | xargs -P 8 -I{} gh api -X POST "repos/$repo/actions/runs/{}/$1" --silent >/dev/null 2>&1 || true
}

# 2. Stop what is running now.
cancel_runs cancel
log "cancelled $cancel_count running or queued run(s)"

# 3. Make sure nothing new can start.
mutate gh api -X PUT "repos/$repo/actions/permissions" -F enabled=false --silent
log "GitHub Actions disabled"

# 4. Catch anything that slipped in between 2 and 3.
cancel_runs cancel
log "second sweep: cancelled $cancel_count more run(s)"

# 5. Take Copilot off every open issue it holds.
copilot_assignments() {
  # shellcheck disable=SC2016 # $i belongs to jq, not to the shell
  gh api --paginate "repos/$repo/issues?state=open&per_page=100" \
    --jq '.[] | select(has("pull_request") | not) | . as $i | $i.assignees[]? | select(.login | test("copilot"; "i")) | "\($i.number) \(.login)"' 2>/dev/null || true
}
unassigned=0 unassign_failed=0
while read -r number login; do
  [ -n "${number:-}" ] || continue
  # The REST login for the agent has two spellings; try the one GitHub reported, then the other.
  if out="$(mutate gh api -X DELETE "repos/$repo/issues/$number/assignees" -f "assignees[]=$login" --silent 2>&1)" \
    || out="$(mutate gh api -X DELETE "repos/$repo/issues/$number/assignees" -f "assignees[]=copilot-swe-agent[bot]" --silent 2>&1)"; then
    unassigned=$((unassigned + 1))
  else
    unassign_failed=$((unassign_failed + 1))
    log "could not unassign $login from issue #$number: $(printf '%s' "$out" | head -n 1)"
  fi
done <<<"$(copilot_assignments)"
log "removed Copilot from $unassigned issue(s)"

# 6. Verify, and force-cancel anything stubborn.
engaged=1
if [ "$dry" -eq 0 ]; then
  round=1
  while :; do
    rm -f "$tmp/list_failed"
    remaining="$(active_run_ids)"
    if [ -e "$tmp/list_failed" ]; then
      engaged=0
      log "could not list workflow runs, so I cannot confirm that nothing is running"
      break
    fi
    [ -n "$remaining" ] || break
    if [ "$round" -gt 3 ]; then
      engaged=0
      log "STILL RUNNING after 3 force-cancel rounds: $(printf '%s' "$remaining" | tr '\n' ' ')"
      break
    fi
    log "round $round: runs still active, force-cancelling"
    cancel_runs force-cancel
    sleep "$retry_sleep"
    round=$((round + 1))
  done
  [ "$(actions_enabled)" = "false" ] || { engaged=0; log "Actions is NOT confirmed disabled"; }
  [ -z "$(copilot_assignments)" ] || { engaged=0; log "Copilot is still assigned to: $(copilot_assignments | tr '\n' ';')"; }
fi
[ "$unassign_failed" -eq 0 ] || engaged=0

elapsed=$((SECONDS - start))

if [ "$dry" -eq 1 ]; then
  echo "================ DRY RUN FINISHED in ${elapsed}s, nothing was changed ================"
  exit 0
fi

if [ "$engaged" -eq 1 ]; then
  record_issue "Kill switch engaged ($(date -u +%Y-%m-%dT%H:%M:%SZ))" \
    "scripts/kill-switch.sh was run for $repo. Actions disabled, ${unassigned} Copilot assignment(s) removed, finished in ${elapsed}s. Undo with: scripts/kill-switch.sh --resume"
  echo "================ KILL SWITCH ENGAGED in ${elapsed}s ================"
else
  echo "================ NOT FULLY ENGAGED after ${elapsed}s, read the lines above ================"
fi
if [ "$elapsed" -gt 60 ]; then
  echo "WARNING: this took longer than 60 seconds."
fi
echo
echo "DO THIS BY HAND NOW (GitHub has no API for it):"
echo "  GitHub -> your profile picture -> Copilot settings -> Cloud agent"
echo "  -> Repository access -> 'No repositories'"
echo "To undo: scripts/kill-switch.sh --resume"

[ "$engaged" -eq 1 ]
