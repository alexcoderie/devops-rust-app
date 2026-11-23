# Harness controls: kill switch and audit log

Two safety controls for the agent factory. Both are plain scripts in `scripts/`, tested
in CI (`Script tests` job, part of `gate`) against a simulated GitHub.

## Kill switch

One command, run from your own computer, logged in as the repository owner (`gh auth login`).
It is not a workflow on purpose: a kill switch must not depend on the system it stops.

```sh
scripts/kill-switch.sh --dry-run   # rehearse: prints what it would do, changes nothing
scripts/kill-switch.sh             # engage (target: under 60 seconds, it prints the time)
scripts/kill-switch.sh --resume    # undo: turn GitHub Actions back on, as it was before
```

Engaging cancels every queued and running run, switches GitHub Actions off, sweeps again for
stragglers, takes Copilot off every open issue, and then **checks**. If it cannot prove that
nothing is running and Copilot is unassigned, it says `NOT FULLY ENGAGED` and exits 1.
It also opens an issue as a permanent record.

GitHub has no API for the Copilot cloud-agent switch, so the last lines of output remind you
to do it by hand: profile picture -> Copilot settings -> Cloud agent -> Repository access ->
**No repositories**.

## Audit log

Every issue event, pull request event, CI run, deploy and push to `main` becomes one JSON line
on the `audit-log` branch, in `audit/YYYY-MM.jsonl`:

| field | meaning |
|---|---|
| `ts` | when it was recorded (UTC) |
| `actor`, `actor_type`, `is_agent` | who did it, and whether it was the agent |
| `event`, `action`, `detail` | what happened (`detail` has event-specific facts, e.g. who approved a deploy) |
| `ticket`, `pr`, `ref`, `sha`, `run_url` | which ticket it served and where to look |

```sh
scripts/audit-show.sh                  # everything, one line per event
scripts/audit-show.sh --ticket 12      # the full story of ticket #12
scripts/audit-show.sh --agent          # only what the agent did
scripts/audit-show.sh --json | jq 'select(.event == "workflow_run" and .detail.workflow == "Fly Deploy")'
scripts/audit-show.sh --json | jq 'select(.ticket == null and .event == "pull_request_target")'   # gaps
```

A `ticket` of `null` means the pull request did not say `Closes #N` and GitHub had no issue
link either. Fix the habit, not the log: the agent instructions require `Closes #N`.

### One-time setup

1. Merge this change, then protect the log branch: **Settings -> Rules -> Rulesets -> New branch
   ruleset**, target the branch `audit-log`, enforcement *Active*, tick **Restrict deletions** and
   **Block force pushes**, and add no bypass. (Do not require pull requests on it.)
2. Open any issue. Within a minute a run named `Audit Log` appears under Actions and the
   `audit-log` branch is created.

## Things only real GitHub can confirm (do these once)

The tests use a simulated GitHub, so these assumptions need one live check:

1. **Does cancelling stop an agent session?** Assign a small ticket to Copilot, then run
   `scripts/kill-switch.sh` while the session is working. Confirm the session ends and note the
   time the script reports. If the session survives, the Copilot setting above is your real off switch.
2. **Do agent runs appear as workflow runs?** While a session is active, run
   `gh run list --repo OWNER/REPO --status in_progress`.
3. **Does unassigning work?** After the kill switch, the issue must show no Copilot assignee.
   If the script reports it could not unassign, tell me the exact error.
4. **Are the agent's events recorded?** Workflows on the agent's pull requests may wait for you to
   click **Approve and run workflows**. Check that its `opened` and `synchronize` events appear
   in `scripts/audit-show.sh --agent` and that `ticket` is filled in.
5. **Rehearse the release.** Run `scripts/kill-switch.sh --resume` and confirm the Actions
   permissions are what they were (Settings -> Actions -> General).

## Limits to know

- The audit workflow records events only while GitHub Actions is on. During a kill switch the
  record is the issue the script opens.
- A change to `.github/workflows/audit.yml` or `scripts/` takes effect once merged. Pull requests
  cannot alter how their own events are recorded (`pull_request_target` runs the version on
  `main`), but read any pull request touching those paths line by line.
- A failed `Audit Log` run means an event was **not** recorded. It shows as a red run in Actions.

