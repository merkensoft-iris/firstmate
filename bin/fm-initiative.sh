#!/usr/bin/env bash
# fm-initiative.sh - named initiative trackers and their cross-home status views.
#
# Usage:
#   fm-initiative.sh new <slug> --goal <text> [--name <text>] [--owner <text>]
#   fm-initiative.sh add <slug> <task-id>... [--home <home>]
#   fm-initiative.sh remove <slug> <task-id>... [--home <home>]
#   fm-initiative.sh close <slug>
#   fm-initiative.sh reopen <slug>
#   fm-initiative.sh list [--all] [--json]
#   fm-initiative.sh show <slug> [--json]
#   fm-initiative.sh board [<slug>]
#   fm-initiative.sh --help
#
# An initiative is one record under data/initiatives/<slug>.json in this home.
# docs/configuration.md ("Initiative trackers") owns the record schema, the
# backlog tag, and the reserved automatic-refresh fields; this header owns the
# command mechanics.
#
# Membership is the union of two sources:
#   - explicit members in the record, added with `add` as <task-id> in <home>,
#     where <home> is `main` (this home, the default) or a second mate id from
#     this home's data/secondmates.md;
#   - tagged tasks: any backlog or done-archive task in any reachable home whose
#     body carries the initiative tag line docs/configuration.md defines.
#
# new, add, remove, close, and reopen are the only writers. Each rewrites one
# record atomically under state/.initiatives.lock and never touches a backlog.
# add refuses a home that is neither `main` nor a registered second mate.
#
# list, show, and board gather state on demand and are strictly read-only
# toward every home: they write nothing under data/ or state/, arm nothing, and
# never mutate a backlog (board alone writes its page, below). The gatherer
# reads, for this home and every registered second mate:
#   - data/backlog.md and data/done-archive.md, so finished tasks already pruned
#     into the archive still resolve;
#   - for a second mate, its published state/home-summary.json ledger, used only
#     to say what an in-flight task is doing or why it is stuck.
# A local second mate is read directly after bin/fm-ff-lib.sh's seeded-home
# validation; a remote one through `bin/fm-on.sh <id> fm-remote-file.sh get`,
# the same path-confined transport bin/fm-fleet-snapshot.sh (and so
# bin/fm-bearings-snapshot.sh) uses for remote ledgers. Homes are read
# concurrently, and every read is bounded by FM_INITIATIVE_TIMEOUT seconds.
# Both backlog files are parsed by `bin/fm-fleet-snapshot.sh --backlog-records`,
# the one backlog parser. For an in-flight task in this home the current worker
# state comes from bin/fm-crew-state.sh (forge reads disabled); these per-task
# reads also run concurrently, each bounded the same.
#
# A home that cannot be read is never dropped: it is listed as unreachable with
# its reason, and each member there resolves to `unreachable` (with the member's
# recorded last-known state when the record carries one). A home whose backlog
# file is absent is reachable with no tasks; an absent done archive is normal.
#
# Member states: done, in_flight, queued, blocked, held (held for the captain),
# missing (not found in that home's backlog or done archive), unreachable.
# A captain hold is `held`; any other hold, an unresolved blocker, or a worker
# reporting blocked or failed is `blocked`. Done carries the PR URL or report
# path and completion date the backlog recorded.
#
# Initiative status, first match wins: `no tasks yet` (no members), `complete`
# (every member done), `waiting on the captain` (any held), `needs attention`
# (any blocked, missing, or unreachable), `under way` (any in flight), `queued`.
#
# Views:
#   list   one line per active initiative (--all adds closed ones): status,
#          done/total, nonzero state counts, owner; then any unreadable record
#          and every unreachable home.
#   show   the drill-down for one initiative, members grouped by state.
#   --json prints the gathered model (schema fm-initiatives.v1) instead.
#   board  writes the list, or with <slug> the drill-down, as a static page at
#          $FM_HOME/.lavish/initiatives-board.html and opens it with lavish-axi
#          when `bin/fm-bootstrap.sh lavish-compatible` passes. Otherwise it
#          says Lavish is unavailable on stderr and prints the plain-text view
#          on stdout, exiting 0. The page is view-only; nothing polls it.
#
# Environment:
#   FM_HOME / FM_DATA_OVERRIDE / FM_STATE_OVERRIDE   home addressed
#   FM_INITIATIVE_TIMEOUT      per-read bound in seconds (default 10)
#   FM_INITIATIVE_MAX_BYTES    per-file byte bound (default 1048576, the
#                              remote transport's own safety bound)
#   FM_INITIATIVE_CREW_STATE   crew-state reader (default bin/fm-crew-state.sh)
#   FM_INITIATIVE_NOW          UTC ISO time stamped on new records and output
#
# Exit status: 0 on success (including unreachable homes), 1 on a refused or
# failed command, 2 on a usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REGISTRY="$DATA/secondmates.md"
INITIATIVES="$DATA/initiatives"
LOCK="$STATE/.initiatives.lock"
BOARD="$FM_HOME/.lavish/initiatives-board.html"
TIMEOUT=${FM_INITIATIVE_TIMEOUT:-10}
MAX_BYTES=${FM_INITIATIVE_MAX_BYTES:-1048576}
CREW_STATE=${FM_INITIATIVE_CREW_STATE:-$SCRIPT_DIR/fm-crew-state.sh}
NOW=${FM_INITIATIVE_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
TODAY=${NOW%%T*}

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-ff-lib.sh"  # validate_secondmate_home: shared seeded-home boundary checks
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"  # fm_lock_acquire_wait_bounded / fm_lock_release

die() { printf 'fm-initiative: %s\n' "$1" >&2; exit 1; }
usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}
usage_error() { printf 'fm-initiative: %s\n' "$1" >&2; usage >&2; exit 2; }

for v in TIMEOUT MAX_BYTES; do
  case "${!v}" in ''|*[!0-9]*|0) die "$v must be a positive integer: ${!v}" ;; esac
done
command -v jq >/dev/null 2>&1 || die "jq not found"

valid_slug() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]; }
valid_task() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
record_path() { printf '%s/%s.json\n' "$INITIATIVES" "$1"; }

TMP=
LOCK_HELD=0
cleanup() {
  [ "$LOCK_HELD" -eq 0 ] || fm_lock_release "$LOCK"
  [ -z "$TMP" ] || rm -rf -- "$TMP"
}
trap cleanup EXIT
make_tmp() {
  [ -n "$TMP" ] && return 0
  TMP=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-initiative.XXXXXX") || die "could not create scratch directory"
}

# --- record writers ------------------------------------------------------------

with_lock() {  # <command...>
  local rc=0
  mkdir -p "$STATE" || die "state directory unavailable: $STATE"
  fm_lock_acquire_wait_bounded "$LOCK" "$TIMEOUT" || die "initiative records are locked by another writer (pid ${FM_LOCK_HELD_PID:-unknown})"
  LOCK_HELD=1
  "$@" || rc=$?
  fm_lock_release "$LOCK"
  LOCK_HELD=0
  return "$rc"
}

write_record() {  # <path> <json>
  local path=$1 json=$2 tmp
  mkdir -p "$INITIATIVES" || die "cannot create $INITIATIVES"
  tmp=$(umask 077; mktemp "$INITIATIVES/.write.XXXXXX") || die "cannot stage record"
  if ! printf '%s\n' "$json" | jq . > "$tmp"; then
    rm -f -- "$tmp"
    die "cannot stage record"
  fi
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; die "cannot write $path"; }
}

read_record() {  # <slug> -> validated record json on stdout
  local slug=$1 path
  path=$(record_path "$slug")
  [ -f "$path" ] && [ ! -L "$path" ] || die "no initiative named $slug"
  jq -e --arg slug "$slug" '
    select(.schema == "fm-initiative.v1" and .slug == $slug and (.members | type) == "array")
  ' "$path" 2>/dev/null || die "initiative record is unreadable or not fm-initiative.v1: $path"
}

registered_home() {  # <home>
  [ "$1" = main ] && return 0
  secondmate_registry_line_for_id "$REGISTRY" "$1"
}

cmd_new() {
  local slug=${1:-} name='' goal='' owner=captain
  [ -n "$slug" ] || usage_error "new needs a slug"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --goal) goal=${2:-}; shift 2 || usage_error "--goal needs a value" ;;
      --name) name=${2:-}; shift 2 || usage_error "--name needs a value" ;;
      --owner) owner=${2:-}; shift 2 || usage_error "--owner needs a value" ;;
      *) usage_error "unknown argument: $1" ;;
    esac
  done
  valid_slug "$slug" || die "slug must be lowercase letters, digits, dot, dash, or underscore (at most 64): $slug"
  [ -n "$goal" ] || usage_error "new needs --goal"
  [ -n "$name" ] || name=$slug
  case "$goal$name$owner" in *$'\n'*) die "name, goal, and owner must each be one line" ;; esac
  with_lock new_locked "$slug" "$name" "$goal" "$owner"
}
new_locked() {
  local path
  path=$(record_path "$1")
  [ ! -e "$path" ] || die "initiative $1 already exists: $path"
  write_record "$path" "$(jq -n --arg slug "$1" --arg name "$2" --arg goal "$3" --arg owner "$4" --arg today "$TODAY" '
    {schema:"fm-initiative.v1",slug:$slug,name:$name,goal:$goal,owner:$owner,
     status:"active",created:$today,members:[],refresh:null}')"
  printf 'created initiative %s: %s\n' "$1" "$(record_path "$1")"
}

cmd_members() {  # <add|remove> <slug> <task-id>... [--home <home>]
  local op=$1 slug=${2:-} home=main tasks=() t
  [ -n "$slug" ] || usage_error "$op needs a slug"
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --home) home=${2:-}; shift 2 || usage_error "--home needs a value" ;;
      -*) usage_error "unknown argument: $1" ;;
      *) tasks+=("$1"); shift ;;
    esac
  done
  [ "${#tasks[@]}" -gt 0 ] || usage_error "$op needs at least one task id"
  for t in "${tasks[@]}"; do valid_task "$t" || die "not a task id: $t"; done
  if [ "$op" = add ]; then
    registered_home "$home" || die "home $home is neither main nor a registered second mate in $REGISTRY"
  fi
  with_lock members_locked "$op" "$slug" "$home" "${tasks[@]}"
}
members_locked() {
  local op=$1 slug=$2 home=$3 record updated
  shift 3
  record=$(read_record "$slug") || exit 1
  updated=$(printf '%s' "$record" | jq --arg op "$op" --arg home "$home" --arg today "$TODAY" \
    --args '
    reduce $ARGS.positional[] as $t (.;
      if $op == "add" then
        if any(.members[]; .task == $t and .home == $home) then .
        else .members += [{task:$t,home:$home,added:$today}] end
      else .members |= map(select((.task == $t and .home == $home) | not)) end)
  ' "$@") || die "cannot update record"
  write_record "$(record_path "$slug")" "$updated"
  printf '%s: %s now has %s explicit member(s)\n' "$op" "$slug" "$(printf '%s' "$updated" | jq '.members | length')"
}

cmd_status() {  # <active|closed> <slug>
  [ -n "${2:-}" ] || usage_error "a slug is required"
  with_lock status_locked "$1" "$2"
}
status_locked() {
  local record
  record=$(read_record "$2") || exit 1
  write_record "$(record_path "$2")" "$(printf '%s' "$record" | jq --arg s "$1" '.status = $s')"
  printf 'initiative %s is now %s\n' "$2" "$1"
}

# --- gatherer ------------------------------------------------------------------

# Read one home into $TMP/homes/<slot>/: backlog.md, archive.md, ledger.json when
# present, plus `reach` (ok|unreachable), `reason`, and `notes` lines.
fetch_remote() {  # <id> <relative-path> <output> -> 0 ok, 3 absent, else failure (reason on stdout)
  local id=$1 rel=$2 out=$3 err rc
  err="$out.err"
  fm_run_timed "$TIMEOUT" "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-file.sh get "$rel" "$MAX_BYTES" \
    > "$out" 2> "$err" < /dev/null
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  rm -f -- "$out"
  if [ "$rc" -eq 124 ]; then
    printf 'timed out after %ss reading %s' "$TIMEOUT" "$rel"
    return 1
  fi
  if grep -Eq 'file is not a non-symlink regular file|file parent is unavailable' "$err" 2>/dev/null; then
    return 3
  fi
  printf '%s' "$(grep -v '^[[:space:]]*$' "$err" 2>/dev/null | head -n 1 | cut -c1-200)"
  [ -s "$err" ] || printf 'remote read of %s failed (exit %s)' "$rel" "$rc"
  return 1
}

copy_local() {  # <file> <output> -> 0 ok, 3 absent, else failure (reason on stdout)
  local file=$1 out=$2 bytes
  [ -e "$file" ] || return 3
  if [ -L "$file" ] || [ ! -f "$file" ]; then
    printf '%s is not a regular file' "$file"
    return 1
  fi
  LC_ALL=C head -c "$((MAX_BYTES + 1))" "$file" > "$out" 2>/dev/null || { printf 'cannot read %s' "$file"; return 1; }
  bytes=$(LC_ALL=C wc -c < "$out" | tr -d ' ')
  if [ "$bytes" -gt "$MAX_BYTES" ]; then
    rm -f -- "$out"
    printf '%s exceeds %s bytes' "$file" "$MAX_BYTES"
    return 1
  fi
}

read_home() {  # <slot-dir> <id> <kind> <home-path>
  local dir=$1 id=$2 kind=$3 home=$4 reason rc
  if [ "$kind" = local ] && ! validate_secondmate_home "$id" "$home" 2>/dev/null; then
    printf 'unreachable\n' > "$dir/reach"
    printf 'invalid home %s: %s\n' "$home" "$VALIDATION_ERROR" > "$dir/reason"
    return
  fi
  [ "$kind" != local ] || home=$VALIDATED_HOME
  read_one() {  # <relative-path> <output>
    case "$kind" in
      remote) fetch_remote "$id" "$1" "$2" ;;
      main) copy_local "$DATA/${1#data/}" "$2" ;;
      *) copy_local "$home/$1" "$2" ;;
    esac
  }
  reason=$(read_one data/backlog.md "$dir/backlog.md"); rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
    printf 'unreachable\n' > "$dir/reach"
    printf '%s\n' "$reason" > "$dir/reason"
    return
  fi
  [ "$rc" -eq 0 ] || printf 'no backlog file\n' >> "$dir/notes"
  printf 'ok\n' > "$dir/reach"
  reason=$(read_one data/done-archive.md "$dir/archive.md"); rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || printf 'done archive unavailable: %s\n' "$reason" >> "$dir/notes"
  if [ "$kind" != main ]; then
    reason=$(read_one state/home-summary.json "$dir/ledger.json"); rc=$?
    case "$rc" in
      0) jq -e '.schema == "fm-secondmate-home-summary.v1" and (.active_children | type) == "array"
               and (.holds | type) == "array" and (.decisions_open | type) == "array"' \
           "$dir/ledger.json" >/dev/null 2>&1 \
           || { rm -f -- "$dir/ledger.json"; printf 'home summary is not a valid fm-secondmate-home-summary.v1 ledger\n' >> "$dir/notes"; } ;;
      3) printf 'no published home summary, so in-flight detail is unavailable\n' >> "$dir/notes" ;;
      *) printf 'home summary unavailable: %s\n' "$reason" >> "$dir/notes" ;;
    esac
  fi
}

parse_home() {  # <slot-dir> -> writes records.json
  local dir=$1 combined="$1/combined.md"
  : > "$combined"
  [ ! -f "$dir/backlog.md" ] || cat "$dir/backlog.md" >> "$combined"
  if [ -f "$dir/archive.md" ]; then
    printf '\n' >> "$combined"
    sed 's/^##[[:space:]]\{1,\}Archived.*/## Done/' "$dir/archive.md" >> "$combined"
  fi
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --backlog-records "$combined" > "$dir/records.json" 2> "$dir/parse.err" \
    || { printf '[]' > "$dir/records.json"; printf 'backlog could not be parsed\n' >> "$dir/notes"; return; }
  jq '.records | map(select(.structured == true))' "$dir/records.json" > "$dir/records.tmp" \
    && mv -f -- "$dir/records.tmp" "$dir/records.json"
}

home_json() {  # <slot-dir>
  local dir=$1 ledger=null
  [ ! -f "$dir/ledger.json" ] || ledger=$(cat "$dir/ledger.json")
  [ -f "$dir/records.json" ] || printf '[]' > "$dir/records.json"
  jq -n --arg id "$(cat "$dir/id")" --arg kind "$(cat "$dir/kind")" \
    --arg reach "$(cat "$dir/reach" 2>/dev/null || echo unreachable)" \
    --arg reason "$(cat "$dir/reason" 2>/dev/null || true)" \
    --arg notes "$(cat "$dir/notes" 2>/dev/null || true)" \
    --slurpfile records "$dir/records.json" --argjson ledger "$ledger" '
    {id:$id,kind:$kind,reachable:($reach == "ok"),
     reason:(if $reach == "ok" then null elif $reason == "" then "home could not be read" else $reason end),
     notes:($notes | split("\n") | map(select(length > 0))),
     records:(if $reach == "ok" then $records[0] else [] end),ledger:$ledger}'
}

gather_homes() {  # -> $TMP/homes.json
  local slot=0 line dir pids=()
  make_tmp
  mkdir -p "$TMP/homes"
  add_slot() {  # <id> <kind> <home> [<reason>]
    slot=$((slot + 1))
    dir="$TMP/homes/$slot"
    mkdir -p "$dir"
    printf '%s' "$1" > "$dir/id"
    printf '%s' "$2" > "$dir/kind"
    if [ -n "${4:-}" ]; then
      printf 'unreachable\n' > "$dir/reach"
      printf '%s\n' "$4" > "$dir/reason"
      return
    fi
    { read_home "$dir" "$1" "$2" "$3"; parse_home "$dir"; } &
    pids+=("$!")
  }
  add_slot main main "$FM_HOME"
  if [ -f "$REGISTRY" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in '- '*) ;; *) continue ;; esac
      if secondmate_registry_parse_line "$line"; then
        if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
          add_slot "$SECONDMATE_REGISTRY_ID" remote "$SECONDMATE_REGISTRY_HOME"
        else
          add_slot "$SECONDMATE_REGISTRY_ID" local "$SECONDMATE_REGISTRY_HOME"
        fi
      else
        line=${line#- }
        add_slot "${line%% *}" unknown "" "registry line is malformed in $REGISTRY"
      fi
    done < "$REGISTRY"
  fi
  [ "${#pids[@]}" -eq 0 ] || wait "${pids[@]}"
  for dir in "$TMP"/homes/*; do home_json "$dir"; done | jq -s . > "$TMP/homes.json" \
    || die "cannot assemble gathered homes"
}

load_records() {  # -> $TMP/records.json: [{file,ok,reason,record}]
  local f slug
  make_tmp
  {
    if [ -d "$INITIATIVES" ]; then
      for f in "$INITIATIVES"/*.json; do
        [ -e "$f" ] || continue
        slug=$(basename "$f" .json)
        if [ ! -L "$f" ] && jq -e --arg slug "$slug" \
            '.schema == "fm-initiative.v1" and .slug == $slug and (.members | type) == "array"
             and all(.members[]; (.task | type) == "string" and (.home | type) == "string")' "$f" >/dev/null 2>&1; then
          jq -c --arg file "$f" '{file:$file,ok:true,reason:null,record:.}' "$f"
        else
          jq -cn --arg file "$f" '{file:$file,ok:false,reason:"not a valid fm-initiative.v1 record",record:null}'
        fi
      done
    fi
  } | jq -s . > "$TMP/records.json" || die "cannot read initiative records"
}

# The single classification model. Input: $homes, $records, $crew; output the
# fm-initiatives.v1 object.
# shellcheck disable=SC2016 # jq program text, not shell expansions.
MODEL_JQ='
  def tags: [ (.body_lines // [])[]
              | ((capture("^[Ii]nitiatives?:[[:space:]]*(?<v>.+)$")? | .v) // empty)
              | split(",")[] | gsub("^[[:space:]]+|[[:space:]]+$"; "") | select(length > 0) ];
  def crew_parse:
    (capture("^state:[[:space:]]*(?<state>[^ ·]+)(?:[[:space:]]*·[[:space:]]*source:[[:space:]]*[^ ·]+)?(?:[[:space:]]*·[[:space:]]*(?<detail>.*))?$")?) // null;
  def classify($home; $task):
    ([ $home.records[] | select(.id == $task) ][0]) as $r
    | if $r == null then {state:"missing",detail:"not found in this home backlog or done archive"}
      else
        {title:$r.title,repo:$r.repo,kind:$r.kind,pr_url:$r.pr_url,report_path:$r.report_path,
         completion:(if $r.completion.verb == null then null else $r.completion end)} as $base
        | if $r.state == "done" then $base + {state:"done",detail:null}
          elif $r.hold_reason != null and $r.hold_kind == "captain" then
            $base + {state:"held",detail:$r.hold_reason,hold_until:$r.hold_until,hold_bucket:$r.hold_bucket}
          elif $r.hold_reason != null then $base + {state:"blocked",detail:("hold: " + $r.hold_reason)}
          elif (($r.unresolved_blocker_ids // []) | length) > 0 then
            $base + {state:"blocked",detail:("waiting on " + ($r.unresolved_blocker_ids | join(", ")))}
          elif $r.state == "queued" then $base + {state:"queued",detail:null}
          elif $home.kind == "main" then
            (($crew[$task] // "") | crew_parse) as $c
            | if $c == null then $base + {state:"in_flight",detail:null}
              elif ($c.state == "blocked" or $c.state == "failed") then
                $base + {state:"blocked",detail:($c.state + (if ($c.detail // "") == "" then "" else ": " + $c.detail end))}
              else $base + {state:"in_flight",detail:($c.state + (if ($c.detail // "") == "" then "" else ": " + $c.detail end))} end
          else
            ($home.ledger // {}) as $l
            | ([ ($l.holds // [])[] | select(.id == $task and .source == "child-state") ][0]) as $h
            | ([ ($l.active_children // [])[] | select(.id == $task) ][0]) as $a
            | ([ ($l.decisions_open // [])[] | select(.id == $task) ][0]) as $d
            | if $h != null then $base + {state:"blocked",detail:$h.reason}
              elif $d != null then $base + {state:"in_flight",detail:("waiting on a decision: " + ($d.summary // $d.verb // ""))}
              elif $a != null then $base + {state:"in_flight",detail:("working" + (if ($a.doing // "") == "" then "" else ": " + $a.doing end))}
              else $base + {state:"in_flight",detail:null} end
          end
      end;
  def resolve($m):
    ([ $homes[] | select(.id == $m.home) ][0]) as $home
    | {task:$m.task,home:$m.home,source:$m.source,observed:($m.observed // null)}
      + (if $home == null then {state:"unreachable",detail:("home " + $m.home + " is not a registered second mate")}
         elif ($home.reachable | not) then {state:"unreachable",detail:("home unreachable: " + $home.reason)}
         else classify($home; $m.task) end);
  def summary:
    (reduce .[] as $m ({total:0,done:0,in_flight:0,queued:0,blocked:0,held:0,missing:0,unreachable:0};
       .total += 1 | .[$m.state] += 1)) as $c
    | {counts:$c,
       status:(if $c.total == 0 then "no tasks yet"
               elif $c.done == $c.total then "complete"
               elif $c.held > 0 then "waiting on the captain"
               elif ($c.blocked + $c.missing + $c.unreachable) > 0 then "needs attention"
               elif $c.in_flight > 0 then "under way"
               else "queued" end)};
  def order: {held:0,blocked:1,in_flight:2,queued:3,done:4,missing:5,unreachable:6}[.state];
  {schema:"fm-initiatives.v1",generated:$now,
   homes:[ $homes[] | {id,kind,reachable,reason,notes} ],
   unreadable_records:[ $records[] | select(.ok | not) | {file,reason} ],
   initiatives:[ $records[] | select(.ok) | .record as $rec
     | ([ $rec.members[] | {task,home,observed,source:"record"} ]) as $explicit
     | ([ $homes[] | select(.reachable) as $h | $h.records[]
          | select(any(tags[]; . == $rec.slug))
          | {task:.id,home:$h.id,observed:null,source:"tag"} ]) as $tagged
     | ([ $explicit[] as $e
          | $e + {source:(if any($tagged[]; .task == $e.task and .home == $e.home) then "record+tag" else "record" end)} ]
        + [ $tagged[] | select(. as $t | any($explicit[]; .task == $t.task and .home == $t.home) | not) ]
        | map(resolve(.)) | sort_by([order, .home, .task])) as $members
     | {slug:$rec.slug,name:($rec.name // $rec.slug),goal:($rec.goal // ""),owner:($rec.owner // ""),
        status:($rec.status // "active"),created:($rec.created // null),refresh:($rec.refresh // null),
        progress:($members | summary),members:$members} ]
   | sort_by(.slug)}
'

gather() {  # [<slug>] -> $TMP/model.json
  local only=${1:-} ids id pids=()
  load_records
  if [ -n "$only" ]; then
    jq -e --arg s "$only" 'any(.[]; .ok and .record.slug == $s)' "$TMP/records.json" >/dev/null \
      || die "no readable initiative named $only in $INITIATIVES"
    jq --arg s "$only" 'map(select(.ok and .record.slug == $s))' "$TMP/records.json" > "$TMP/records.one" \
      && mv -f -- "$TMP/records.one" "$TMP/records.json"
  fi
  gather_homes
  # First pass without worker state names this home's in-flight members, so the
  # bounded crew-state reads cover exactly those tasks.
  jq -rn --slurpfile homes "$TMP/homes.json" --slurpfile records "$TMP/records.json" --arg now "$NOW" \
    '($homes[0]) as $homes | ($records[0]) as $records | {} as $crew | '"$MODEL_JQ"'
     | [.initiatives[].members[] | select(.home == "main" and .state == "in_flight") | .task] | unique[]' \
    > "$TMP/inflight" || die "cannot classify initiative members"
  mkdir -p "$TMP/crew"
  ids=$(cat "$TMP/inflight")
  for id in $ids; do
    valid_task "$id" && [ -f "$STATE/$id.meta" ] || continue
    {
      FM_CREW_STATE_NO_FORGE=1 fm_run_timed "$TIMEOUT" "$CREW_STATE" "$id" 2>/dev/null < /dev/null | head -n 1 \
        | jq -Rc --arg id "$id" '{($id):.}' > "$TMP/crew/$id"
    } &
    pids+=("$!")
  done
  [ "${#pids[@]}" -eq 0 ] || wait "${pids[@]}"
  : > "$TMP/crew.jsonl"
  for id in $ids; do
    [ -f "$TMP/crew/$id" ] && cat "$TMP/crew/$id" >> "$TMP/crew.jsonl"
  done
  jq -n --slurpfile homes "$TMP/homes.json" --slurpfile records "$TMP/records.json" \
    --slurpfile crewrows "$TMP/crew.jsonl" --arg now "$NOW" \
    '($homes[0]) as $homes | ($records[0]) as $records | (reduce $crewrows[] as $r ({}; . + $r)) as $crew | '"$MODEL_JQ" \
    > "$TMP/model.json" || die "cannot assemble initiative status"
}

# --- views ---------------------------------------------------------------------

# shellcheck disable=SC2016 # jq program text, not shell expansions.
TEXT_JQ='
  def counts_text:
    [ (if .in_flight > 0 then "\(.in_flight) in flight" else empty end),
      (if .queued > 0 then "\(.queued) queued" else empty end),
      (if .blocked > 0 then "\(.blocked) blocked" else empty end),
      (if .held > 0 then "\(.held) held for the captain" else empty end),
      (if .missing > 0 then "\(.missing) not found" else empty end),
      (if .unreachable > 0 then "\(.unreachable) unreachable" else empty end) ]
    | if length == 0 then "" else " (" + join(", ") + ")" end;
  def progress_text: "\(.progress.status), \(.progress.counts.done)/\(.progress.counts.total) done\(.progress.counts | counts_text)";
  def member_line:
    "- \(.task) (\(.home))"
    + (if (.title // "") != "" then " - " + .title else "" end)
    + (if .state == "done" then
         (if .completion != null then " - \(.completion.verb) \(.completion.date // "")" else "" end)
       elif .state == "held" then " - " + .detail + (if (.hold_until // null) != null then " (until \(.hold_until))" else "" end)
       elif (.detail // null) != null then " - " + .detail
       else "" end)
    + (if (.pr_url // null) != null then " - " + .pr_url else "" end)
    + (if (.report_path // null) != null and (.pr_url // null) == null then " - report " + .report_path else "" end)
    + (if .state == "unreachable" and .observed != null then " (last recorded: \(.observed.state // "unknown") at \(.observed.at // "unknown time"))" else "" end)
    + (if .source == "tag" then " [tagged]" else "" end);
  def homes_text($notes_too):
    [ .homes[] | select(.reachable | not) | "- \(.id): \(.reason)" ] as $down
    | [ .homes[] | select(.reachable) | .id as $id | .notes[] | "- \($id): \(.)" ] as $notes
    | (if ($down | length) > 0 then ["", "Homes not reached (tasks tagged there cannot be seen):"] + $down else [] end)
      + (if $notes_too and ($notes | length) > 0 then ["", "Notes:"] + $notes else [] end);
  def list_text($all):
    [ .initiatives[] | select($all or .status != "closed")
      | "- \(.slug) - \(.name): \(progress_text) - owner \(.owner)" + (if .status == "closed" then " [closed]" else "" end) ] as $rows
    | (if ($rows | length) == 0 then ["No initiatives yet. Create one with bin/fm-initiative.sh new <slug> --goal \"<goal>\"."] else ["Initiatives:"] + $rows end)
      + (if (.unreadable_records | length) > 0 then ["", "Unreadable initiative records:"] + [ .unreadable_records[] | "- \(.file): \(.reason)" ] else [] end)
      + homes_text(false)
    | join("\n");
  def show_text:
    . as $m | .initiatives[0] as $i
    | ["Initiative: \($i.name) (\($i.slug))",
       "Goal: \($i.goal)",
       "Owner: \($i.owner) | Created: \($i.created // "unknown") | Status: \($i.status)",
       "Progress: \($i | progress_text)",
       "Automatic refresh: " + (if $i.refresh == null then "none recorded; this view was gathered on demand at \($m.generated)"
                                else "last at \($i.refresh.at // "unknown time") by \($i.refresh.by // "unknown")" end)]
      + ([ [ ["held","Held for the captain"],["blocked","Blocked"],["in_flight","In flight"],["queued","Queued"],
           ["done","Done"],["missing","Not found"],["unreachable","Unreachable"] ][] as [$s,$heading]
         | [ $i.members[] | select(.state == $s) | member_line ] as $rows
         | if ($rows | length) == 0 then empty else ["", $heading + ":"] + $rows end ] | add // [])
      + (if ($i.members | length) == 0 then ["", "No tasks yet. Add one with bin/fm-initiative.sh add \($i.slug) <task-id>, or tag a task body with \"initiative: \($i.slug)\"."] else [] end)
      + ($m | homes_text(true))
    | join("\n");
'

cmd_list() {
  local json=0 all=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      --all) all=true ;;
      *) usage_error "unknown argument: $1" ;;
    esac
    shift
  done
  gather
  if [ "$json" -eq 1 ]; then
    jq --argjson all "$all" 'if $all then . else .initiatives |= map(select(.status != "closed")) end' "$TMP/model.json"
  else
    jq -r --argjson all "$all" "$TEXT_JQ list_text(\$all)" "$TMP/model.json"
  fi
}

cmd_show() {
  local slug='' json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      -*) usage_error "unknown argument: $1" ;;
      *) [ -z "$slug" ] || usage_error "show takes one slug"; slug=$1 ;;
    esac
    shift
  done
  [ -n "$slug" ] || usage_error "show needs a slug"
  valid_slug "$slug" || die "not an initiative slug: $slug"
  gather "$slug"
  if [ "$json" -eq 1 ]; then
    cat "$TMP/model.json"
  else
    jq -r "$TEXT_JQ show_text" "$TMP/model.json"
  fi
}

# shellcheck disable=SC2016 # jq program text, not shell expansions.
BOARD_JQ='
  def e: tostring | @html;
  def pill: "<span class=\"pill s-\(.)\">\(. | gsub("_"; " ") | e)</span>";
  def link: if (.pr_url // null) != null then "<a href=\"\(.pr_url | e)\">\(.pr_url | e)</a>"
            elif (.report_path // null) != null then "<code>\(.report_path | e)</code>" else "" end;
  def bar: .progress.counts as $c
    | "<div class=\"bar\"><span style=\"width:\(if $c.total == 0 then 0 else ($c.done * 100 / $c.total | floor) end)%\"></span></div>";
  def card:
    "<section class=\"card\"><header><h2>\(.name | e) <small>\(.slug | e)</small></h2>"
    + "<p class=\"status\">\(.progress.status | e) - \(.progress.counts.done)/\(.progress.counts.total) done</p></header>"
    + bar + "<p class=\"goal\">\(.goal | e)</p><p class=\"meta\">Owner \(.owner | e) - created \(.created // "unknown" | e) - \(.status | e)</p>"
    + (if (.members | length) == 0 then "<p class=\"meta\">No tasks yet.</p>" else
        "<table><thead><tr><th>State</th><th>Task</th><th>Home</th><th>Detail</th><th>Link</th></tr></thead><tbody>"
        + ([ .members[] | "<tr><td>\(.state | pill)</td><td><strong>\(.task | e)</strong><br>\((.title // "") | e)</td><td>\(.home | e)</td><td>\(((.detail // (if .completion != null then "\(.completion.verb) \(.completion.date // "")" else "" end))) | e)</td><td>\(link)</td></tr>" ] | join(""))
        + "</tbody></table>" end)
    + "</section>";
  . as $m
  | "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
  + "<title>Initiatives</title><style>"
  + ":root{--paper:#f6ecd3;--card:#fffdf7;--ink:#241c14;--body:#3f3224;--muted:#6f5e46;--line:#ddc89c;--sea:#2f6b4f;--gold:#b5791c;--rust:#a93a1f;--ocean:#3c7ea6;font-family:Jost,ui-sans-serif,system-ui,sans-serif}"
  + "@media (prefers-color-scheme:dark){:root{--paper:#1a2238;--card:#222c49;--ink:#fbf4e2;--body:#e7d6ae;--muted:#9c8a6c;--line:#2a3656}}"
  + "body{margin:0;background:var(--paper);color:var(--body);padding:24px 16px}main{max-width:1100px;margin:0 auto}h1{color:var(--ink);margin:0 0 4px}"
  + ".card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px;margin:16px 0;min-width:0}"
  + ".card h2{margin:0;color:var(--ink);font-size:1.2rem}.card h2 small{color:var(--muted);font-weight:500;font-size:.85rem}"
  + ".status{margin:4px 0;font-weight:600}.goal{margin:8px 0}.meta{color:var(--muted);font-size:.9rem;margin:4px 0}"
  + ".bar{height:8px;background:var(--line);border-radius:999px;overflow:hidden}.bar span{display:block;height:100%;background:var(--sea)}"
  + "table{width:100%;border-collapse:collapse;margin-top:12px;table-layout:fixed}th,td{text-align:left;padding:6px;border-top:1px solid var(--line);vertical-align:top;overflow-wrap:anywhere;font-size:.92rem}"
  + "a{color:var(--ocean)}.pill{display:inline-block;padding:2px 8px;border-radius:999px;font-size:.8rem;color:#fffdf7;background:var(--muted)}"
  + ".s-done{background:var(--sea)}.s-in_flight{background:var(--ocean)}.s-held{background:var(--gold)}.s-blocked,.s-missing,.s-unreachable{background:var(--rust)}"
  + "</style></head><body><main><h1>Initiatives</h1><p class=\"meta\">Gathered on demand at \($m.generated | e). Rerun the board to refresh.</p>"
  + ([ $m.initiatives[] | select(.status != "closed" or $single) | card ] | join(""))
  + (if ([ $m.initiatives[] | select(.status != "closed" or $single) ] | length) == 0 then "<p>No initiatives yet.</p>" else "" end)
  + ([ $m.homes[] | select(.reachable | not) | "<li><strong>\(.id | e)</strong>: \(.reason | e)</li>" ] as $down
     | if ($down | length) > 0 then "<section class=\"card\"><h2>Homes not reached</h2><ul>" + ($down | join("")) + "</ul></section>" else "" end)
  + "</main></body></html>"
'

cmd_board() {
  local slug=${1:-} single=false
  [ $# -le 1 ] || usage_error "board takes at most one slug"
  if [ -n "$slug" ]; then
    valid_slug "$slug" || die "not an initiative slug: $slug"
    single=true
  fi
  gather "$slug"
  if ! "$SCRIPT_DIR/fm-bootstrap.sh" lavish-compatible >/dev/null 2>&1; then
    printf 'Lavish is unavailable (lavish-axi is missing or below its supported version floor), so here is the plain-text view instead.\n' >&2
    if [ "$single" = true ]; then
      jq -r "$TEXT_JQ show_text" "$TMP/model.json"
    else
      jq -r "$TEXT_JQ list_text(false)" "$TMP/model.json"
    fi
    return 0
  fi
  mkdir -p "$(dirname "$BOARD")" || die "cannot create $(dirname "$BOARD")"
  if ! jq -r --argjson single "$single" "$BOARD_JQ" "$TMP/model.json" > "$BOARD.tmp" \
      || ! mv -f -- "$BOARD.tmp" "$BOARD"; then
    rm -f -- "$BOARD.tmp"
    die "cannot write $BOARD"
  fi
  printf 'board: %s\n' "$BOARD"
  lavish-axi "$BOARD" < /dev/null
}

case "${1:-}" in
  new) shift; cmd_new "$@" ;;
  add|remove) op=$1; shift; cmd_members "$op" "$@" ;;
  close) cmd_status closed "${2:-}" ;;
  reopen) cmd_status active "${2:-}" ;;
  list) shift; cmd_list "$@" ;;
  show) shift; cmd_show "$@" ;;
  board) shift; cmd_board "$@" ;;
  -h|--help) usage; exit 0 ;;
  '') usage_error "a command is required" ;;
  *) usage_error "unknown command: $1" ;;
esac
