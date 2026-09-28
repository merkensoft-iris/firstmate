#!/usr/bin/env bash
# Tests for fm-initiative.sh, the named initiative trackers and their views.
#
# The fixture fleet is one main home, one local second mate, one remote second
# mate reached through a fake ssh that runs the real bin/fm-remote-file.sh
# against a fixture home (so the path-confined remote transport is exercised,
# not stubbed), and one remote second mate whose host refuses the connection.
# Worker current state comes from a fake crew-state reader, and Lavish
# availability from a fake lavish-axi version on PATH, so no case touches a
# real endpoint, host, or browser.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INIT="$ROOT/bin/fm-initiative.sh"
TMP_ROOT=$(fm_test_tmproot fm-initiative)
NOW=2026-09-28T12:00:00Z

make_local_mate() {  # <path> <id>
  local mate=$1 id=$2
  mkdir -p "$mate/state" "$mate/data" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf '%s\n' "$id" > "$mate/.fm-secondmate-home"
}

# make_fakes <dir>: fake ssh (real fm-remote-file.sh against the decoded fixture
# home; host `down` refuses), fake crew-state, and a lavish-axi whose version
# comes from FM_TEST_LAVISH_VERSION and whose calls are logged.
make_fakes() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
if [ "$host" = down ]; then
  echo "ssh: connect to host down port 22: Connection refused" >&2
  exit 255
fi
shift 2
remote_home=$(perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$3")
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done \
  < <(perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$4")
printf '%s\t%s\n' "$host" "${args[*]}" >> "$FM_TEST_SSH_LOG"
[ "${args[0]}" = fm-remote-file.sh ] || exit 91
FM_HOME="$remote_home" exec "$FM_TEST_ROOT/bin/fm-remote-file.sh" "${args[@]:1}"
SH
  cat > "$dir/fake-crew-state" <<'SH'
#!/usr/bin/env bash
case "$1" in
  main-flight) echo "state: blocked · source: status-log · waiting on a login" ;;
  *) echo "state: working · source: run-step · review" ;;
esac
SH
  cat > "$dir/lavish-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf '%s\n' "${FM_TEST_LAVISH_VERSION:-0.0.1}"; exit 0; fi
printf '%s\n' "$*" >> "$FM_TEST_LAVISH_LOG"
echo "session: live"
SH
  chmod +x "$dir/fake-ssh" "$dir/fake-crew-state" "$dir/lavish-axi"
}

# make_fleet <name>: prints the main home path.
make_fleet() {
  local home="$TMP_ROOT/$1" mate remote down
  mate="$TMP_ROOT/$1-mate"
  remote="$TMP_ROOT/$1-remote"
  down="$TMP_ROOT/$1-down"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  make_local_mate "$mate" alpha
  mkdir -p "$remote/data" "$remote/state" "$down"
  mate=$(cd "$mate" && pwd -P)
  remote=$(cd "$remote" && pwd -P)
  cat > "$home/data/secondmates.md" <<EOF
# Secondmates

- alpha - Local mate. (home: $mate; scope: alpha work; projects: p; added 2026-09-01)
- beta - Remote mate. (host: beta-host; root: /remote/root; home: $remote; scope: beta work; projects: p; added 2026-09-01)
- gamma - Remote mate that is down. (host: down; root: /remote/root; home: $down; scope: gamma work; projects: p; added 2026-09-01)
EOF
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] main-flight - Wire the payment webhook (repo: shop) (kind: ship) (since 2026-09-20)
## Queued
- [ ] main-queued - Write the refund docs (repo: shop) (kind: docs) (since 2026-09-21)
- [ ] main-held - Pick a payment provider (repo: shop) (kind: captain) (since 2026-09-21) (hold: choose between two providers) (hold-kind: captain)
- [ ] main-dep - Launch checkout blocked-by: main-queued (repo: shop) (kind: ship) (since 2026-09-22)
- [ ] other-work - Unrelated chore (repo: shop) (kind: ship) (since 2026-09-22)
  initiative: search
## Done
- [x] main-landed - Add the cart API https://github.com/o/shop/pull/7 (repo: shop) (kind: ship) (merged 2026-09-19)
EOF
  cat > "$home/data/done-archive.md" <<'EOF'

## Archived 2026-09-10
- [x] main-old-scout - Survey payment providers - data/main-old-scout/report.md (repo: shop) (kind: scout) (reported 2026-09-05)
  initiative: payments
EOF
  cat > "$mate/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] alpha-work - Build the ledger export (repo: ledger) (kind: ship) (since 2026-09-23)
- [ ] alpha-stuck - Migrate the invoices table (repo: ledger) (kind: ship) (since 2026-09-23)
  initiative: payments
## Queued
## Done
EOF
  jq -n --arg home "$mate" '{schema:"fm-secondmate-home-summary.v1",hold_classifier_schema:"fm-captain-hold-buckets.v1",
    home:$home,generated:"2026-09-28T11:00:00Z",generated_epoch:1,valid:true,state:"active_child_work",invalidity:{kind:null,ids:[]},
    active_children:[{id:"alpha-work",state:"working",doing:"running the export tests"}],
    decisions_open:[],holds:[{id:"alpha-stuck",reason:"waiting on database credentials",source:"child-state"}],
    queued:[],landed:[],endpoints:[],counts:{},omitted:[]}' > "$mate/state/home-summary.json"
  cat > "$remote/data/backlog.md" <<'EOF'
# Backlog

## In flight
## Queued
- [ ] beta-queued - Localize the checkout page (repo: web) (kind: ship) (since 2026-09-24)
## Done
EOF
  cat > "$remote/data/done-archive.md" <<'EOF'

## Archived 2026-09-15
- [x] beta-shipped - Add currency formatting https://github.com/o/web/pull/3 (repo: web) (kind: ship) (merged 2026-09-14)
  initiative: payments, search
EOF
  printf 'main-flight\n' > "$home/state/main-flight.meta"
  printf '%s\n' "$home"
}

run_init() {  # <home> <fakebin> <args...>
  local home=$1 fakebin=$2
  shift 2
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_ROOT="$ROOT" \
    FM_SSH_BIN="$fakebin/fake-ssh" FM_TEST_SSH_LOG="$home.ssh.log" \
    FM_TEST_LAVISH_LOG="$home.lavish.log" \
    FM_INITIATIVE_CREW_STATE="$fakebin/fake-crew-state" FM_INITIATIVE_NOW="$NOW" \
    FM_INITIATIVE_TIMEOUT=15 PATH="$fakebin:$PATH" "$INIT" "$@"
}

seed_payments() {  # <home> <fakebin>
  run_init "$1" "$2" new payments --name "Payments revamp" --goal "Take card payments end to end" --owner captain >/dev/null \
    || fail "new payments failed"
  run_init "$1" "$2" add payments main-flight main-queued main-held main-dep main-landed main-gone >/dev/null \
    || fail "add main members failed"
  run_init "$1" "$2" add payments alpha-work --home alpha >/dev/null || fail "add alpha member failed"
  run_init "$1" "$2" add payments beta-queued --home beta >/dev/null || fail "add beta member failed"
  run_init "$1" "$2" add payments gamma-task --home gamma >/dev/null || fail "add gamma member failed"
  # A last-known observation, the shape the follow-up automatic refresh records.
  jq '(.members[] | select(.task == "gamma-task")) += {observed:{state:"in_flight",at:"2026-09-27T09:00:00Z"}}' \
    "$1/data/initiatives/payments.json" > "$1/payments.tmp" && mv "$1/payments.tmp" "$1/data/initiatives/payments.json"
}

tree_digest() {  # <dir>...: content and path digest of every file
  find "$@" -type f -print | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s\n' "$f" "$(cksum < "$f")"
  done
}

test_record_commands() {
  local home fakebin out rc rec
  home=$(make_fleet rec)
  fakebin="$TMP_ROOT/rec-bin"; make_fakes "$fakebin"
  out=$(run_init "$home" "$fakebin" new payments --goal "Take card payments" 2>&1) || fail "new failed: $out"
  rec="$home/data/initiatives/payments.json"
  assert_equals "fm-initiative.v1|payments|payments|captain|active|2026-09-28|0|null" \
    "$(jq -r '[.schema,.slug,.name,.owner,.status,.created,(.members|length),(.refresh|tostring)] | join("|")' "$rec")" \
    "new writes a versioned record with an empty refresh stamp"
  out=$(run_init "$home" "$fakebin" new payments --goal again 2>&1); rc=$?
  expect_code 1 "$rc" "duplicate new refuses"
  out=$(run_init "$home" "$fakebin" new Bad/Slug --goal x 2>&1); rc=$?
  expect_code 1 "$rc" "bad slug refuses"
  out=$(run_init "$home" "$fakebin" add payments some-task --home nowhere 2>&1); rc=$?
  expect_code 1 "$rc" "unregistered home refuses"
  assert_contains "$out" "neither main nor a registered second mate" "refusal names the home rule"
  run_init "$home" "$fakebin" add payments t1 t2 >/dev/null || fail "add failed"
  run_init "$home" "$fakebin" add payments t1 >/dev/null || fail "repeat add failed"
  run_init "$home" "$fakebin" add payments t1 --home beta >/dev/null || fail "add to remote home failed"
  jq '.extra = "kept"' "$rec" > "$rec.tmp" && mv "$rec.tmp" "$rec"
  run_init "$home" "$fakebin" remove payments t2 >/dev/null || fail "remove failed"
  assert_equals "t1@main,t1@beta|kept" \
    "$(jq -r '([.members[] | "\(.task)@\(.home)"] | join(",")) + "|" + .extra' "$rec")" \
    "add dedupes per home, remove drops one member, unknown fields survive"
  run_init "$home" "$fakebin" new search --goal "Better search" >/dev/null || fail "second new failed"
  run_init "$home" "$fakebin" close search >/dev/null || fail "close failed"
  out=$(run_init "$home" "$fakebin" list 2>&1) || fail "list failed: $out"
  assert_not_contains "$out" "- search -" "a closed initiative leaves the default list"
  out=$(run_init "$home" "$fakebin" list --all 2>&1) || fail "list --all failed: $out"
  assert_contains "$out" "- search - search: " "list --all shows the closed initiative"
  assert_contains "$out" "[closed]" "a closed initiative is marked"
  run_init "$home" "$fakebin" reopen search >/dev/null || fail "reopen failed"
  assert_equals active "$(jq -r .status "$home/data/initiatives/search.json")" "reopen restores active"
  assert_absent "$home/state/.initiatives.lock" "writers release their lock"
  pass "record commands create, edit, close, and reopen initiatives"
}

test_gather_across_homes() {
  local home fakebin json out
  home=$(make_fleet gather)
  fakebin="$TMP_ROOT/gather-bin"; make_fakes "$fakebin"
  seed_payments "$home" "$fakebin"
  json=$(run_init "$home" "$fakebin" show payments --json 2>&1) || fail "show --json failed: $json"
  member() { printf '%s' "$json" | jq -r --arg t "$1" --arg h "$2" \
    '.initiatives[0].members[] | select(.task == $t and .home == $h) | [.state,(.detail // "-"),(.pr_url // .report_path // "-"),.source] | join("|")'; }
  assert_equals "blocked|blocked: waiting on a login|-|record" "$(member main-flight main)" "main in-flight worker state comes from crew state"
  assert_equals "queued|-|-|record" "$(member main-queued main)" "queued main task"
  assert_equals "held|choose between two providers|-|record" "$(member main-held main)" "captain hold is held for the captain"
  assert_equals "blocked|waiting on main-queued|-|record" "$(member main-dep main)" "unresolved blocker is blocked"
  assert_equals "done|-|https://github.com/o/shop/pull/7|record" "$(member main-landed main)" "done task carries its PR"
  assert_equals "missing|not found in this home backlog or done archive|-|record" "$(member main-gone main)" "absent task is missing"
  assert_equals "done|-|data/main-old-scout/report.md|tag" "$(member main-old-scout main)" "tagged task in the done archive resolves with its report"
  assert_equals "in_flight|working: running the export tests|-|record" "$(member alpha-work alpha)" "local mate in-flight detail comes from its ledger"
  assert_equals "blocked|waiting on database credentials|-|tag" "$(member alpha-stuck alpha)" "local mate child hold is blocked"
  assert_equals "queued|-|-|record" "$(member beta-queued beta)" "remote mate queued task is read over the transport"
  assert_equals "done|-|https://github.com/o/web/pull/3|tag" "$(member beta-shipped beta)" "remote done archive tag resolves"
  assert_equals "unreachable" "$(member gamma-task gamma | cut -d'|' -f1)" "member in a down home is unreachable"
  assert_contains "$(member gamma-task gamma)" "Connection refused" "unreachable member carries the reason"
  assert_equals "" "$(member other-work main)" "a task tagged for another initiative stays out"
  assert_equals "12|3|1|2|3|1|1|1|waiting on the captain" \
    "$(printf '%s' "$json" | jq -r '.initiatives[0].progress | [.counts.total,.counts.done,.counts.in_flight,.counts.queued,.counts.blocked,.counts.held,.counts.missing,.counts.unreachable,.status] | join("|")')" \
    "progress counts every state"
  assert_equals "gamma|false" "$(printf '%s' "$json" | jq -r '.homes[] | select(.reachable | not) | "\(.id)|\(.reachable)"')" \
    "only the down home is unreachable, and it is listed"
  assert_grep "beta-host	fm-remote-file.sh get data/backlog.md" "$home.ssh.log" "remote backlog read goes through fm-remote-file.sh"
  assert_grep "beta-host	fm-remote-file.sh get data/done-archive.md" "$home.ssh.log" "remote done archive read goes through fm-remote-file.sh"

  out=$(run_init "$home" "$fakebin" list 2>&1) || fail "list failed: $out"
  assert_contains "$out" "- payments - Payments revamp: waiting on the captain, 3/12 done (1 in flight, 2 queued, 3 blocked, 1 held for the captain, 1 not found, 1 unreachable) - owner captain" \
    "list line carries status and progress"
  assert_contains "$out" "Homes not reached (tasks tagged there cannot be seen):" "list names unreachable homes"
  assert_contains "$out" "- gamma: ssh: connect to host down port 22: Connection refused" "unreachable home reason is shown"

  out=$(run_init "$home" "$fakebin" show payments 2>&1) || fail "show failed: $out"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c '^Initiative: ')" "drill-down prints its header once"
  assert_equals 12 "$(printf '%s\n' "$out" | grep -cE '^- [a-z-]+ \(')" "drill-down prints one row per member"
  assert_contains "$out" "Goal: Take card payments end to end" "drill-down shows the goal"
  assert_contains "$out" "Automatic refresh: none recorded; this view was gathered on demand at $NOW" "drill-down states the refresh is on demand"
  assert_contains "$out" $'Held for the captain:\n- main-held (main) - Pick a payment provider - choose between two providers' "held section"
  assert_contains "$out" "- main-landed (main) - Add the cart API - merged 2026-09-19 - https://github.com/o/shop/pull/7" "done row with PR"
  assert_contains "$out" "- main-old-scout (main) - Survey payment providers - reported 2026-09-05 - report data/main-old-scout/report.md [tagged]" "archived tagged scout row"
  assert_contains "$out" "(last recorded: in_flight at 2026-09-27T09:00:00Z)" "unreachable member shows its recorded last-known state"
  pass "gatherer resolves members across main, local, remote, and unreachable homes"
}

test_gather_is_read_only() {
  local home fakebin before after out
  home=$(make_fleet ro)
  fakebin="$TMP_ROOT/ro-bin"; make_fakes "$fakebin"
  seed_payments "$home" "$fakebin"
  before=$(tree_digest "$home" "$TMP_ROOT/ro-mate" "$TMP_ROOT/ro-remote")
  out=$(run_init "$home" "$fakebin" list 2>&1) || fail "list failed: $out"
  out=$(run_init "$home" "$fakebin" show payments --json 2>&1) || fail "show failed: $out"
  after=$(tree_digest "$home" "$TMP_ROOT/ro-mate" "$TMP_ROOT/ro-remote")
  assert_equals "$before" "$after" "list and show write nothing in any home"
  pass "gathering is read-only toward every home"
}

test_unreadable_record_and_empty_home() {
  local home fakebin out
  home="$TMP_ROOT/empty"
  mkdir -p "$home/data/initiatives" "$home/state"
  fakebin="$TMP_ROOT/empty-bin"; make_fakes "$fakebin"
  out=$(run_init "$home" "$fakebin" list 2>&1) || fail "empty list failed: $out"
  assert_contains "$out" "No initiatives yet." "empty home says so"
  printf '{"schema":"other"}\n' > "$home/data/initiatives/broken.json"
  run_init "$home" "$fakebin" new solo --goal "One task" >/dev/null || fail "new failed"
  out=$(run_init "$home" "$fakebin" list 2>&1) || fail "list failed: $out"
  assert_contains "$out" "- solo - solo: no tasks yet, 0/0 done - owner captain" "an initiative without members"
  assert_contains "$out" "broken.json: not a valid fm-initiative.v1 record" "an unreadable record is named, not dropped"
  pass "unreadable records and memberless initiatives are reported"
}

test_board_falls_back_and_opens() {
  local home fakebin out err
  home=$(make_fleet board)
  fakebin="$TMP_ROOT/board-bin"; make_fakes "$fakebin"
  seed_payments "$home" "$fakebin"
  err="$TMP_ROOT/board.err"
  out=$(FM_TEST_LAVISH_VERSION=0.0.1 run_init "$home" "$fakebin" board payments 2>"$err") || fail "fallback board failed"
  assert_grep "Lavish is unavailable" "$err" "fallback says Lavish is unavailable"
  assert_contains "$out" "Initiative: Payments revamp (payments)" "fallback prints the plain-text drill-down"
  assert_absent "$home/.lavish/initiatives-board.html" "fallback writes no board"
  assert_absent "$home.lavish.log" "fallback never calls lavish-axi"
  out=$(FM_TEST_LAVISH_VERSION=99.0.0 run_init "$home" "$fakebin" board 2>&1) || fail "board failed: $out"
  assert_contains "$out" "board: $home/.lavish/initiatives-board.html" "board prints its path"
  assert_contains "$out" "session: live" "board relays the lavish session"
  assert_grep "$home/.lavish/initiatives-board.html" "$home.lavish.log" "board opens the page with lavish-axi"
  assert_grep "Payments revamp" "$home/.lavish/initiatives-board.html" "board page carries the initiative"
  assert_grep "https://github.com/o/shop/pull/7" "$home/.lavish/initiatives-board.html" "board page carries PR links"
  assert_grep "Homes not reached" "$home/.lavish/initiatives-board.html" "board page lists unreachable homes"
  pass "board opens with Lavish and falls back to plain text without it"
}

test_backlog_records_mode_parses_only_the_named_file() {
  local home out file
  home=$(make_fleet parse)
  file="$TMP_ROOT/parse-other.md"
  printf '# Backlog\n\n## Queued\n- [ ] only-here - A task (kind: ship) (since 2026-09-01)\n  initiative: payments\n' > "$file"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --backlog-records "$file") || fail "backlog-records failed"
  assert_equals "only-here|queued|initiative: payments" \
    "$(printf '%s' "$out" | jq -r '[.records[] | "\(.id)|\(.state)|\(.body_lines | join(" "))"] | join(",")')" \
    "the named file is parsed, not the home's own backlog"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --backlog-records 2>&1); expect_code 2 "$?" "a missing file argument is a usage error"
  pass "fleet snapshot --backlog-records parses only the named file"
}

test_usage_errors() {
  local out rc
  out=$("$INIT" --help 2>&1); rc=$?
  expect_code 0 "$rc" "--help exits 0"
  assert_contains "$out" "fm-initiative.sh show <slug> [--json]" "--help prints usage"
  out=$("$INIT" frobnicate 2>&1); rc=$?
  expect_code 2 "$rc" "unknown command is a usage error"
  pass "usage errors"
}

test_record_commands
test_gather_across_homes
test_gather_is_read_only
test_unreadable_record_and_empty_home
test_board_falls_back_and_opens
test_backlog_records_mode_parses_only_the_named_file
test_usage_errors
