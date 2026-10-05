#!/usr/bin/env bash
# bridge-feed.sh - one read-only JSON snapshot for the Bridge pane.
#
# Read-only by design: it never drains the wake queue, acknowledges a wake,
# steers a worker, or takes the session lock. The pane polls it on a timer, so
# anything that consumes supervision events would steal them from firstmate.
#
# Sources, each the owner of its fact:
#   fm-fleet-snapshot.sh --json   tasks, backlog holds, PR URLs, worktrees
#   fm-classify-lib.sh            the open-decision fold the wake drain prints
#   ~/.lavish-axi/state.json      board sessions and their chat history
#   lavish /health                which boards a worker is listening on
#   fm-inbox.sh receipts          captain notes still waiting
#
# Usage: bridge-feed.sh [<fm-home>]
set -euo pipefail

FM_HOME=${1:-${FM_HOME:-$HOME/firstmate}}
export FM_HOME
LAVISH_STATE=${LAVISH_AXI_STATE_DIR:-$HOME/.lavish-axi}/state.json
LAVISH_PORT=${LAVISH_AXI_PORT:-4387}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$FM_HOME/bin/fm-fleet-snapshot.sh" --json >"$tmp/snap.json" 2>/dev/null || echo '{}' >"$tmp/snap.json"

# The fold is the drain's own: the snapshot reconciles decisions against live
# worker state and drops those of paused workers, but a paused worker's board
# question still waits on the captain.
# The library is written for callers without errexit, so it runs without it.
set +e
# shellcheck source=/dev/null
. "$FM_HOME/bin/fm-classify-lib.sh"
: >"$tmp/decisions.tsv"
jq -r '.tasks[]? | [.id, (.paths.status_log.path // "")] | @tsv' "$tmp/snap.json" |
  while IFS=$'\t' read -r id status; do
    [ -n "$status" ] && [ -f "$status" ] || continue
    # The fold prints no newline after its last record.
    while IFS=$'\t' read -r key verb note || [ -n "$key" ]; do
      [ -n "$verb" ] || continue
      at=$(grep -oE "\[at=[0-9]+\] \[key=${key}\]" "$status" | tail -1 | grep -oE '[0-9]+' | head -1 || true)
      printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$key" "$verb" "${at:-0}" "$note" >>"$tmp/decisions.tsv"
    done < <(status_open_decisions "$status")
  done
jq -R -s 'split("\n") | map(select(length > 0) | split("\t") |
  {task: .[0], key: .[1], verb: .[2], at: (.[3] | tonumber), note: (.[4:] | join("\t"))})' \
  "$tmp/decisions.tsv" >"$tmp/decisions.json"
set -e

if [ -r "$LAVISH_STATE" ]; then
  jq '[.sessions[]? | select(.status != "ended") | {
        key, file, url, pending: (.pending_prompts // 0),
        last_role: (.chat[-1].role // null),
        last_at: (.chat[-1].at // .updated_at // null),
        updated_at
      }]' "$LAVISH_STATE" >"$tmp/boards.json"
else
  echo '[]' >"$tmp/boards.json"
fi
curl -s --max-time 2 "http://127.0.0.1:$LAVISH_PORT/health" >"$tmp/health.json" 2>/dev/null || true
jq -e . "$tmp/health.json" >/dev/null 2>&1 || echo '{}' >"$tmp/health.json"

"$FM_HOME/bin/fm-inbox.sh" receipts --all-pending >"$tmp/inbox.json" 2>/dev/null || true
jq -e . "$tmp/inbox.json" >/dev/null 2>&1 || echo '{}' >"$tmp/inbox.json"

jq -n \
  --slurpfile snap "$tmp/snap.json" \
  --slurpfile decisions "$tmp/decisions.json" \
  --slurpfile boards "$tmp/boards.json" \
  --slurpfile health "$tmp/health.json" \
  --slurpfile inbox "$tmp/inbox.json" '
  ($snap[0]) as $s
  | ([$s.tasks[]? | {key: .id, value: .}] | from_entries) as $tasks
  | ([$health[0].listeners[]? | .key] ) as $listening
  # Parked work keeps its open questions in the status log, but the captain set
  # them aside, so they show under holds rather than as decisions waiting now.
  | ([$s.backlog.records[]? | select(.hold_kind != null) | .id]) as $parked
  | def project($t): ($t.backlog.repo // ($t.project // "" | split("/") | last) // "");
    def title($t): (($t.backlog.title // $t.id) | sub("^[^:]+: "; ""));
  {
    generated: ($s.generated // null),
    decisions: [$decisions[0][] | select(.task as $id | $parked | index($id) | not)
      | . as $d | ($tasks[$d.task] // {}) as $t | {
      id: ($d.task + ":" + $d.key), task: $d.task, key: $d.key, verb: $d.verb, at: $d.at,
      project: project($t), title: title($t), note: $d.note,
      urls: ([$d.note | match("https?://[^ )\\]]+"; "g") .string | sub("[,.;:]+$"; "")] + [($t.pr.url // empty)] | unique)
    }],
    boards: [$boards[0][] | . as $b
      | ([$s.tasks[]? | . as $x | select($x.paths.worktree.path != null and ($b.file | startswith($x.paths.worktree.path + "/")))][0]) as $t
      | {
        key, url, pending, last_role, last_at, updated_at,
        listening: ($listening | index($b.key) != null),
        name: ($b.file | split("/") | if last == "index.html" then .[-2] else (last | sub("\\.html?$"; "")) end),
        project: (if $t then project($t) else ($b.file | capture("/\\.treehouse/(?<p>.+)-[0-9a-f]+/").p // "") end),
        task: ($t.id // null),
        # A listener stays armed while the worker makes the next round, so only
        # an open, unparked decision on the board task means the captain is up.
        decision_open: (if $t then ([$decisions[0][] | select(.task == $t.id and ($parked | index($t.id) | not))] | length > 0) else null end)
      }],
    holds: [$s.backlog.records[]? | select(.captain_actionable == true) | {
      task: .id, project: (.repo // ""), title: ((.title // .id) | sub("^[^:]+: "; "")),
      reason: (.hold_reason // ""), age_days: (.hold_age_days // null), pr: (.pr_url // null)
    }],
    holds_other: ([$s.backlog.records[]? | select(.hold_bucket != null and .hold_bucket != "live")] | length),
    # A status line can name someone else PR as prior art, so only a PR recorded
    # in the task record counts as the task own.
    prs: [$s.tasks[]? | select(.pr.url != null and .pr.source == "meta") | . as $t
      | select(([$s.backlog.records[]? | select(.id == $t.id and .captain_actionable == true)] | length) == 0)
      | {task: .id, project: project(.), title: title(.), url: .pr.url, state: (.current_state.state // "unknown")}],
    # Workers with no board yet would otherwise show only as a count.
    workers: [$s.tasks[]? | . as $t
      | select($parked | index($t.id) | not)
      | select(([$boards[0][] | select($t.paths.worktree.path != null and (.file | startswith($t.paths.worktree.path + "/")))] | length) == 0)
      | {task: .id, project: project(.), title: title(.), state: (.current_state.state // "unknown"),
         since: ((.spawn_gen // "") | capture("^s(?<t>[0-9]+)").t // null | if . then tonumber else null end)}],
    underway: ([$s.tasks[]? | select(.current_state.state == "working")] | length),
    inbox: ($inbox[0].pending // [] | length)
  }'
