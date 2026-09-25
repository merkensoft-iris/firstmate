#!/usr/bin/env bash
# Tests for fm-fleet-usage.sh, the fleet-wide usage and signed-in-account table.
#
# Every case drives the script through a fake `quota-axi` and a fake `ssh` on
# PATH, so no case ever opens a real connection or reads a real credential.
# The fake ssh answers canned `quota-axi --full` reports for two hosts and
# refuses a third, and it logs each call so a case can prove one connection per
# host and the BatchMode/ConnectTimeout options. Reset times are asserted with
# TZ=UTC so the local-zone rendering is deterministic on any runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

USAGE="$ROOT/bin/fm-fleet-usage.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-usage)

# make_home <name>: a home whose registry places two mates on host alpha, one on
# beta, one on the unreachable host delta, and one locally.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data"
  cat > "$home/data/secondmates.md" <<'EOF'
# Secondmates

- alpha1 - Own alpha one. (host: alpha; root: /home/agent/work/firstmate; home: /home/agent/mate1; scope: alpha one; projects: p; added 2026-09-18)
- alpha2 - Own alpha two. (host: alpha; root: /home/agent/work/firstmate; home: /home/agent/mate2; scope: alpha two; projects: p; added 2026-09-18)
- beta1 - Own beta. (host: beta; root: /home/agent/work/firstmate; home: /home/agent/mate; scope: beta; projects: p; added 2026-09-18)
- delta1 - Own delta. (host: delta; root: /home/agent/work/firstmate; home: /home/agent/mate; scope: delta; projects: p; added 2026-09-18)
- here1 - Local mate. (home: /tmp/fm-here1; scope: local things; projects: p; added 2026-09-18)
EOF
  printf '%s\n' "$home"
}

# make_fakes <dir> <ssh-log>: fake ssh and quota-axi on a PATH directory.
make_fakes() {
  local dir=$1 log=$2
  mkdir -p "$dir"
  cat > "$dir/ssh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$log'
host=
while [ \$# -gt 0 ]; do
  case "\$1" in
    --) shift; host=\$1; shift; break ;;
    -o) shift ;;
  esac
  shift
done
[ "\$*" = "quota-axi --full" ] || { echo "unexpected remote command: \$*" >&2; exit 99; }
case "\$host" in
  alpha) cat <<'T'
bin: ~/.local/bin/quota-axi
quota[1]{provider,scope,effectivePercentRemaining,spendPriority}:
  claude,all_models,20,0.5
attention[2]{provider,scope,kind,detail,remedy}:
  codex,all,auth_required,Codex sign-in required,none
  claude,all,degraded_source,"oauth, refreshed late",rerun quota-axi --refresh-token SECRET
windows[3]{provider,id,label,percentRemaining,resetsAt,pace,reserve}:
  claude,five_hour,session,20,"2026-09-21T13:39:59.779718+00:00",ahead,-7.2
  claude,seven_day,week,66,"2026-09-25T03:59:59.779749+00:00",behind,13.7
  claude,"model:fable",Fable week,59,"2026-09-25T03:59:59.779749+00:00",behind,32.3
accounts[2]{provider,email,organization,accountId,identityStatus}:
  claude,henry1@example.com,"Example, Inc",429efe32,verified
  codex,hidden,none,none,unknown
attempts[1]{provider,source,status,error}:
  claude,oauth-file,success,none
T
  ;;
  beta) cat <<'T'
attention[1]{provider,scope,kind,detail,remedy}:
  cursor,all,error,sqlite3_unavailable,none
windows[3]{provider,id,label,percentRemaining,resetsAt,pace,reserve}:
  claude,five_hour,session,77.4,"2026-09-21T15:20:00.267234+00:00",behind,16.1
  claude,seven_day,week,55,"2026-09-23T09:00:00.267258+00:00",behind,28.3
  codex,weekly,week,65,"2026-09-27T04:32:14.000Z",ahead,-16.0
accounts[3]{provider,email,organization,accountId,identityStatus}:
  claude,captain@example.com,captain@example.com's Organization,c304,verified
  codex,captain@work.example,none,0de6,unknown
  cursor,hidden,none,none,unknown
T
  ;;
  delta) echo "ssh: connect to host delta port 22: Operation timed out" >&2; exit 255 ;;
  *) echo "unknown host \$host" >&2; exit 98 ;;
esac
SH
  cat > "$dir/quota-axi" <<'SH'
#!/usr/bin/env bash
[ "$*" = "--full" ] || { echo "unexpected local args: $*" >&2; exit 99; }
cat <<'T'
attention[2]{provider,scope,kind,detail,remedy}:
  claude,all,unmeasurable,Keychain read needs approval,none
  copilot,all,auth_required,GitHub Copilot sign-in required,none
windows[2]{provider,id,label,percentRemaining,resetsAt,pace,reserve}:
  codex,five_hour,session,78,"2026-09-21T13:43:53.000Z",behind,49
  codex,weekly,week,65,"2026-09-27T04:32:14.000Z",ahead,-16.0
accounts[3]{provider,email,organization,accountId,identityStatus}:
  claude,hidden,none,none,unknown
  codex,captain@work.example,none,0de6,unknown
  copilot,hidden,none,none,unknown
T
SH
  chmod 0755 "$dir/ssh" "$dir/quota-axi"
}

run_usage() {  # <home> <fakebin> [args...]
  local home=$1 fakebin=$2
  shift 2
  TZ=UTC PATH="$fakebin:$PATH" FM_HOME="$home" "$USAGE" "$@"
}

test_markdown_table_rows_sort_and_unreachable() {
  local home fakebin log out rc
  home=$(make_home md)
  fakebin="$TMP_ROOT/md-bin"; log="$TMP_ROOT/md-ssh.log"
  make_fakes "$fakebin" "$log"
  out=$(run_usage "$home" "$fakebin" 2>"$TMP_ROOT/md.err"); rc=$?
  expect_code 0 "$rc" "table is produced even when one host is unreachable"
  assert_contains "$out" '| host | mates | provider | account | 5h left | 5h resets | 5h pace | week left | week resets | week pace |' "markdown header"
  assert_contains "$out" '| alpha | alpha1,alpha2 | claude | henry1@example.com | 20% | 2026-09-21 13:39 UTC | ahead | 66% | 2026-09-25 03:59 UTC | behind |' "alpha claude row with both windows in the local zone"
  assert_contains "$out" '| beta | beta1 | claude | captain@example.com | 77% | 2026-09-21 15:20 UTC | behind | 55% | 2026-09-23 09:00 UTC | behind |' "beta claude row with a truncated percent"
  assert_contains "$out" '| local | here1 | codex | captain@work.example | 78% | 2026-09-21 13:43 UTC | behind | 65% | 2026-09-27 04:32 UTC | ahead |' "local codex row"
  assert_contains "$out" '| beta | beta1 | codex | captain@work.example | - | - | - | 65% | 2026-09-27 04:32 UTC | ahead |' "a missing five-hour window prints dashes, never a number"
  assert_contains "$out" '| delta | delta1 | - | unreachable: ssh: connect to host delta port 22: Operation timed out | - | - | - | - | - | - |' "unreachable host is a row that says so"
  assert_not_contains "$out" 'model:fable' "model-scoped windows are not rows"
  assert_not_contains "$out" 'cursor' "a provider with no session window and no verified account is omitted"
  assert_not_contains "$out" 'SECRET' "remedy text never reaches the output"
  assert_not_contains "$out" 'copilot' "attention for a provider nobody uses stays quiet"
  # Sort: five-hour remaining ascending, then rows without a window, then failures.
  local order
  order=$(printf '%s\n' "$out" | grep '^| ' | grep -Ev '^\| (host|---)' | awk -F'|' '{ gsub(/ /, "", $2); gsub(/ /, "", $4); print $2 "/" $4 }' | paste -sd' ' -)
  assert_equals 'alpha/claude beta/claude local/codex beta/codex delta/-' "$order" "rows sort by five-hour remaining ascending with dashes and failures last"
  assert_contains "$out" '## attention' "attention section"
  assert_contains "$out" '- delta - read_failed: unreachable: ssh: connect to host delta port 22: Operation timed out' "read failure is listed under attention"
  assert_contains "$out" '- local claude unmeasurable: Keychain read needs approval' "an unmeasurable fleet provider is listed for the host that cannot read it"
  assert_contains "$out" '- alpha claude degraded_source: oauth, refreshed late' "a present provider's attention row keeps its quoted detail"
  assert_not_contains "$out" 'auth_required' "a mate merely not signed into a fleet provider is not attention"
  pass "markdown table, sort, unreachable row, and attention"
}

test_one_connection_per_host_with_batch_mode() {
  local home fakebin log
  home=$(make_home conn)
  fakebin="$TMP_ROOT/conn-bin"; log="$TMP_ROOT/conn-ssh.log"
  make_fakes "$fakebin" "$log"
  run_usage "$home" "$fakebin" >/dev/null 2>&1 || fail "run failed"
  assert_equals 3 "$(wc -l < "$log" | tr -d ' ')" "exactly one ssh connection per remote host"
  assert_equals 1 "$(grep -c -- '-- alpha quota-axi --full' "$log")" "a host shared by two mates is read once"
  assert_equals 3 "$(grep -c 'BatchMode=yes' "$log")" "every connection uses BatchMode"
  assert_equals 3 "$(grep -c 'ConnectTimeout=' "$log")" "every connection carries a connect timeout"
  assert_no_grep 'local' "$log" "the local host is never read over ssh"
  pass "one batch-mode connection per host"
}

test_toon_output() {
  local home fakebin log out
  home=$(make_home toon)
  fakebin="$TMP_ROOT/toon-bin"; log="$TMP_ROOT/toon-ssh.log"
  make_fakes "$fakebin" "$log"
  out=$(run_usage "$home" "$fakebin" --toon 2>&1) || fail "--toon failed: $out"
  assert_contains "$out" 'usage[5]{host,mates,provider,account,fiveHourLeft,fiveHourResetsAt,fiveHourPace,weekLeft,weekResetsAt,weekPace,read}:' "toon usage header with the row count"
  assert_contains "$out" '  alpha,"alpha1,alpha2",claude,henry1@example.com,20,2026-09-21 13:39 UTC,ahead,66,2026-09-25 03:59 UTC,behind,ok' "toon row quotes a comma-bearing field"
  assert_contains "$out" '  delta,delta1,-,unreachable: ssh: connect to host delta port 22: Operation timed out,-,-,-,-,-,-,failed' "toon unreachable row is marked failed"
  assert_contains "$out" 'attention[3]{host,provider,kind,detail}:' "toon attention header"
  assert_contains "$out" '  alpha,claude,degraded_source,"oauth, refreshed late"' "toon attention detail is quoted"
  assert_not_contains "$out" '| host' "toon output carries no markdown table"
  local first
  first=$(printf '%s\n' "$out" | sed -n 2p)
  case "$first" in '  alpha,'*) ;; *) fail "toon rows keep the five-hour sort (first row: $first)" ;; esac
  pass "toon output"
}

test_absent_registry_reads_only_local() {
  local home fakebin log out
  home="$TMP_ROOT/none"; mkdir -p "$home/data"
  fakebin="$TMP_ROOT/none-bin"; log="$TMP_ROOT/none-ssh.log"
  make_fakes "$fakebin" "$log"
  out=$(run_usage "$home" "$fakebin" 2>&1) || fail "absent registry run failed: $out"
  assert_contains "$out" '| local | - | codex | captain@work.example | 78% |' "local row with no mates"
  assert_absent "$log" "no ssh connection without a registry"
  pass "absent registry reads only the local host"
}

test_malformed_registry_and_bad_args_refuse() {
  local home fakebin log out rc
  home="$TMP_ROOT/bad"; mkdir -p "$home/data"
  printf -- '- broken - no suffix here\n' > "$home/data/secondmates.md"
  fakebin="$TMP_ROOT/bad-bin"; log="$TMP_ROOT/bad-ssh.log"
  make_fakes "$fakebin" "$log"
  out=$(run_usage "$home" "$fakebin" 2>&1); rc=$?
  expect_code 1 "$rc" "malformed registry refuses"
  assert_contains "$out" 'malformed secondmate registry entry' "malformed registry is named"
  out=$(run_usage "$home" "$fakebin" --nope 2>&1); rc=$?
  expect_code 2 "$rc" "unknown flag refuses with usage"
  out=$("$USAGE" --help 2>&1); rc=$?
  expect_code 2 "$rc" "--help exits 2"
  assert_contains "$out" 'fm-fleet-usage.sh [--toon] [--help]' "--help prints the usage line"
  pass "malformed registry and bad arguments refuse"
}

test_markdown_table_rows_sort_and_unreachable
test_one_connection_per_host_with_batch_mode
test_toon_output
test_absent_registry_reads_only_local
test_malformed_registry_and_bad_args_refuse
