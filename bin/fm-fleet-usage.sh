#!/usr/bin/env bash
# fm-fleet-usage.sh - one table of LLM usage and signed-in accounts across the fleet.
#
# Usage:
#   fm-fleet-usage.sh [--toon] [--help]
#
# Reads `quota-axi --full` on every host that carries a second mate plus this
# host, and prints one table with the signed-in account beside the usage
# windows. This is the loop firstmate used to hand-roll on every "what is the
# usage across the mates and which account are they on" question.
#
# Hosts come from data/secondmates.md through bin/fm-secondmate-registry-lib.sh
# (never a hand parse). Every remote record contributes its `host:` ssh alias;
# a host that several mates share is read ONCE. Local records and this machine
# itself are the `local` host, read with the local `quota-axi --full`. A missing
# or empty registry still reads the local host. A malformed registry line is a
# fatal error, the same as the other registry consumers.
#
# Transport: one ssh connection per remote host at a time, never more (a burst
# of parallel connections to one host trips sshd throttling), while different
# hosts are read in parallel with a bound. The ssh call uses BatchMode=yes, a
# connect timeout, no agent forwarding, and a hard per-host wall bound from
# bin/fm-timeout-lib.sh, so a hung host becomes a row rather than a hang.
#
# Environment:
#   FM_HOME / FM_DATA_OVERRIDE   home whose data/secondmates.md is read
#   FM_SSH_BIN                   ssh executable (default: ssh)
#   FM_QUOTA_AXI                 local quota-axi executable (default: quota-axi)
#   FM_FLEET_USAGE_REMOTE_CMD    command run over ssh (default: quota-axi --full)
#   FM_FLEET_USAGE_PARALLEL      hosts read concurrently (default: 4)
#   FM_FLEET_USAGE_TIMEOUT       per-host wall bound in seconds (default: 60)
#   FM_SSH_CONNECT_TIMEOUT       ssh ConnectTimeout in seconds (default: 10)
#   TZ                           reset times are rendered in this zone
#
# Output contract (markdown, the default):
#
#   | host | mates | provider | account | 5h left | 5h resets | 5h pace | week left | week resets | week pace | month left | month resets | other |
#
#   One row per host x provider. A provider is "present" on a host when its
#   quota-axi report has any window row, or an account row whose
#   identityStatus is `verified`, or a providers row that shows a configured
#   credential: a source other than unavailable, unknown, or none with a
#   status other than auth_required, or an authStatus of usable or
#   expired_refreshable (a Kimi sign-in between uses). Other providers - never
#   signed in, not installed - are omitted. A present provider with no window
#   at all is still a row, with `-` in every window cell and its reason in
#   `other` as `no window: <reason>`, where the reason is its first quota-axi
#   attention detail, or its status and authStatus when it has none.
#   `account` is the email from the accounts row, or `-` when none.
#   `mates` lists the second mates the registry places on that host, `-` when
#   the host (typically `local`) carries none.
#   `5h` comes from the `five_hour` window; `week` from `seven_day` or
#   `weekly`; `month` from `month_total`, `monthly`, or `month`. `left` is percentRemaining as an integer percent, `resets` is the
#   window's resetsAt rendered in the local zone as `YYYY-MM-DD HH:MM ZONE`,
#   `pace` is the window's pace word (ahead, behind, on_pace, unknown). A
#   missing window prints `-` in all of its cells; no number is ever invented.
#   `other` lists every remaining window that is not model-scoped as
#   `<label> <left>%` joined by `; `, or `-` when there is none.
#   Rows are sorted by `5h left` ascending, numeric rows first, then rows with
#   a window but no five-hour one, then rows with no window, then the read
#   failures. A host whose read failed is
#   still a row: provider `-`, account `unreachable: <first stderr line>` (or
#   `timed out after Ns`, or `no quota-axi output`), and `-` elsewhere.
#
#   After the table, `## attention` lists, one bullet per line as
#   `- <host> <provider> <kind>: <detail>`: every read failure, and the
#   quota-axi attention[] rows of each provider present on that host, and of a
#   provider present on some other host unless the row only says it is not
#   signed in here (`auth_required`). An unmeasurable Claude on this laptop is
#   therefore named, while a mate that never signed into Codex and providers
#   nobody uses anywhere stay quiet. A quota-axi `stale` kind prints as
#   `stale reading`, and a present provider whose authStatus is
#   expired_refreshable adds a `credential expired, refreshable` row saying the
#   stored sign-in expired between uses and renews on the next use, so a
#   usable provider is never read as signed out. Only the kind and detail are
#   ever printed;
#   remedy text, tokens, file contents, and every other quota-axi section stay
#   out of the output. The section prints `- none` when there is nothing to
#   report.
#
# With --toon the same data prints as TOON for agents:
#
#   usage[N]{host,mates,provider,account,fiveHourLeft,fiveHourResetsAt,fiveHourPace,weekLeft,weekResetsAt,weekPace,read,monthLeft,monthResetsAt,other}:
#   attention[M]{host,provider,kind,detail}:
#
#   `read` is `ok` or `failed`; a failed row carries the failure text in
#   `account` exactly as the markdown does. The month and other fields follow
#   `read` so a positional reader of the earlier fields is unaffected. Values containing a comma, quote,
#   or surrounding space are double-quoted with inner quotes doubled.
#
# Exit status is 0 whenever the table was produced, even when some hosts failed
# (their rows say so); 1 for a usage error, an unreadable registry, or a
# malformed registry line; 2 for --help.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REGISTRY="$DATA/secondmates.md"

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

SSH_BIN=${FM_SSH_BIN:-ssh}
QUOTA_AXI=${FM_QUOTA_AXI:-quota-axi}
REMOTE_CMD=${FM_FLEET_USAGE_REMOTE_CMD:-quota-axi --full}
PARALLEL=${FM_FLEET_USAGE_PARALLEL:-4}
HOST_TIMEOUT=${FM_FLEET_USAGE_TIMEOUT:-60}
CONNECT_TIMEOUT=${FM_SSH_CONNECT_TIMEOUT:-10}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"; exit 2; }

for v in PARALLEL HOST_TIMEOUT CONNECT_TIMEOUT; do
  case "${!v}" in ''|*[!0-9]*|0) die "$v must be a positive integer: ${!v}" ;; esac
done

# --- internal worker: read one host into an output directory -----------------
# fm-fleet-usage.sh __read <host> <dir>   (invoked through xargs -P, never by hand)
if [ "${1:-}" = __read ]; then
  host=$2; dir=$3
  if [ "$host" = local ]; then
    fm_run_timed "$HOST_TIMEOUT" "$QUOTA_AXI" --full > "$dir/out" 2> "$dir/err" < /dev/null
  else
    fm_run_timed "$HOST_TIMEOUT" "$SSH_BIN" \
      -o BatchMode=yes -o "ConnectTimeout=$CONNECT_TIMEOUT" \
      -o ForwardAgent=no -o ClearAllForwardings=yes \
      -- "$host" "$REMOTE_CMD" > "$dir/out" 2> "$dir/err" < /dev/null
  fi
  printf '%s\n' "$?" > "$dir/rc"
  exit 0
fi

FORMAT=markdown
while [ $# -gt 0 ]; do
  case "$1" in
    --toon) FORMAT=toon ;;
    -h|--help) usage ;;
    *) printf 'error: unknown argument: %s\n' "$1" >&2; usage ;;
  esac
  shift
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet-usage.XXXXXX") || die "could not create scratch directory"
trap 'rm -rf -- "$TMP"' EXIT INT TERM HUP

# --- hosts from the registry --------------------------------------------------
# hosts file: <host>\t<comma-joined mate ids>; `local` always present and first.
: > "$TMP/hosts"
declare -a HOST_ORDER=(local)
declare -a HOST_MATES=("")
add_mate() {  # <host> <mate-id>
  local h=$1 id=$2 i
  for i in "${!HOST_ORDER[@]}"; do
    if [ "${HOST_ORDER[$i]}" = "$h" ]; then
      HOST_MATES[i]="${HOST_MATES[$i]:+${HOST_MATES[$i]},}$id"
      return 0
    fi
  done
  HOST_ORDER+=("$h")
  HOST_MATES+=("$id")
}
if [ -e "$REGISTRY" ] || [ -L "$REGISTRY" ]; then
  [ -f "$REGISTRY" ] && [ ! -L "$REGISTRY" ] || die "secondmate registry is unavailable or unsafe: $REGISTRY"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || die "malformed secondmate registry entry: $line"
    if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
      add_mate "$SECONDMATE_REGISTRY_HOST" "$SECONDMATE_REGISTRY_ID"
    else
      add_mate local "$SECONDMATE_REGISTRY_ID"
    fi
  done < "$REGISTRY"
fi
for i in "${!HOST_ORDER[@]}"; do
  mkdir -p "$TMP/h/${HOST_ORDER[$i]}"
  printf '%s\n' "${HOST_ORDER[$i]}" >> "$TMP/hosts"
done

# --- read every host: one connection per host, hosts in parallel --------------
xargs -P "$PARALLEL" -I '{}' "$SCRIPT_DIR/fm-fleet-usage.sh" __read '{}' "$TMP/h/{}" < "$TMP/hosts"

# --- helpers ------------------------------------------------------------------
if date --version >/dev/null 2>&1; then DATE_FLAVOR=gnu; else DATE_FLAVOR=bsd; fi
# Render an ISO-8601 instant (fractional seconds, Z or +HH:MM offset) in the
# local zone. Prints the raw string when neither GNU nor BSD date can parse it.
local_time() {
  local iso=$1 s off
  case "$iso" in
    *Z) off=+0000; s=${iso%Z} ;;
    *[+-][0-9][0-9]:[0-9][0-9]) off="${iso: -6:3}${iso: -2}"; s=${iso%??????} ;;
    *) printf '%s\n' "$iso"; return 0 ;;
  esac
  s="${s%%.*}$off"                      # drop fractional seconds, keep the offset
  if [ "$DATE_FLAVOR" = gnu ]; then
    date -d "$s" '+%Y-%m-%d %H:%M %Z' 2>/dev/null && return 0
  else
    date -j -f '%Y-%m-%dT%H:%M:%S%z' "$s" '+%Y-%m-%d %H:%M %Z' 2>/dev/null && return 0
  fi
  printf '%s\n' "$iso"
}

toon_quote() {
  local v=$1
  case "$v" in
    ''|*[,\"]*|' '*|*' ') v=${v//\"/\"\"}; printf '"%s"' "$v" ;;
    *) printf '%s' "$v" ;;
  esac
}

md_cell() { printf '%s' "${1//|/\\|}"; }

# Section-aware TOON row extractor: prints the fields of the rows under the
# named top-level section, unit-separator delimited, with TOON quoting removed.
toon_rows() {  # <file> <section>
  awk -v want="$2" -v us="$US" '
    function unquote(s) { gsub(/""/, "\"", s); return s }
    /^[A-Za-z_"]+(\[[0-9]+\])?(\{[^}]*\})?:/ {
      sec = $0; sub(/[\[{:].*/, "", sec); gsub(/"/, "", sec); next
    }
    sec != want || substr($0, 1, 2) != "  " { next }
    {
      line = substr($0, 3); n = 0; field = ""; inq = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (inq) {
          if (c == "\"") { if (substr(line, i + 1, 1) == "\"") { field = field "\""; i++ } else inq = 0 }
          else field = field c
        } else if (c == "\"") inq = 1
        else if (c == ",") { out[++n] = field; field = "" }
        else field = field c
      }
      out[++n] = field
      s = out[1]; for (i = 2; i <= n; i++) s = s us out[i]
      print s
    }' "$1"
}

# --- per-host extraction ------------------------------------------------------
# Internal record files use the ASCII unit separator so an empty field survives
# `read` (a tab-separated empty field would collapse).
US=$(printf '\037')
# rows: sortkey US host US mates US provider US account US 5h US 5h_reset US 5h_pace US wk US wk_reset US wk_pace US read US mo US mo_reset US other
# attention: host US provider US kind US detail
: > "$TMP/rows"
: > "$TMP/attention"
: > "$TMP/present"
for i in "${!HOST_ORDER[@]}"; do
  host=${HOST_ORDER[$i]}; mates=${HOST_MATES[$i]:--}; dir="$TMP/h/$host"
  rc=$(cat "$dir/rc" 2>/dev/null || printf 1)
  failure=
  if [ "$rc" = 124 ]; then
    failure="timed out after ${HOST_TIMEOUT}s"
  elif [ "$rc" != 0 ]; then
    first=$(grep -m1 . "$dir/err" 2>/dev/null || true)
    failure="unreachable: ${first:-exit $rc}"
  elif ! grep -Eq '^(windows|accounts)\[' "$dir/out" 2>/dev/null; then
    failure="no quota-axi output"
  fi
  if [ -n "$failure" ]; then
    printf '3%s%s%s%s%s-%s%s%s-%s-%s-%s-%s-%s-%sfailed%s-%s-%s-\n' "$US" "$host" "$US" "$mates" "$US" "$US" "$failure" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" >> "$TMP/rows"
    printf '%s%s-%sread_failed%s%s\n' "$host" "$US" "$US" "$US" "$failure" >> "$TMP/attention"
    continue
  fi
  toon_rows "$dir/out" windows > "$dir/windows"
  toon_rows "$dir/out" accounts > "$dir/accounts"
  toon_rows "$dir/out" attention > "$dir/attention"
  toon_rows "$dir/out" providers > "$dir/providers"
  # Present providers, in first-seen order: any window, a verified account, or
  # a providers row showing a configured credential (see the header).
  { awk -F"$US" '{ print $1 }' "$dir/windows"
    awk -F"$US" '$5 == "verified" { print $1 }' "$dir/accounts"
    awk -F"$US" '($3 != "unavailable" && $3 != "unknown" && $3 != "none" && $3 != "" && $4 != "auth_required") || $5 == "usable" || $5 == "expired_refreshable" { print $1 }' "$dir/providers"
  } | awk 'NF && !seen[$0]++' > "$dir/present"
  cat "$dir/present" >> "$TMP/present"
  while IFS= read -r provider; do
    acct=$(awk -F"$US" -v p="$provider" '$1 == p { print $2; exit }' "$dir/accounts")
    case "$acct" in ''|hidden|none) acct=- ;; esac
    h_left=-; h_reset=-; h_pace=-; w_left=-; w_reset=-; w_pace=-; m_left=-; m_reset=-; other=; windows=0
    while IFS="$US" read -r _ id label pct reset pace _; do
      [ -n "$id" ] || continue
      windows=1
      case "$pct" in ''|*[!0-9.]*) pct=- ;; *) pct=${pct%%.*} ;; esac
      [ -n "$pace" ] || pace=-
      case "$reset" in ''|none|unknown) reset=- ;; *) reset=$(local_time "$reset") ;; esac
      case "$id" in
        five_hour) h_left=$pct; h_reset=$reset; h_pace=$pace ;;
        seven_day|weekly) w_left=$pct; w_reset=$reset; w_pace=$pace ;;
        month_total|monthly|month) m_left=$pct; m_reset=$reset ;;
        model:*) ;;
        *) [ "$pct" = - ] || pct="${pct}%"; other="${other:+$other; }${label:-$id} $pct" ;;
      esac
    done < <(awk -F"$US" -v p="$provider" '$1 == p' "$dir/windows")
    if [ "$h_left" != - ]; then key=0; elif [ "$windows" = 1 ]; then key=1; else
      key=2
      reason=$(awk -F"$US" -v p="$provider" '$1 == p && $4 != "" { print $4; exit }' "$dir/attention")
      [ -n "$reason" ] || reason=$(awk -F"$US" -v p="$provider" '$1 == p { print "status " $4 " (auth " $5 ")"; exit }' "$dir/providers")
      other="no window: ${reason:-no measurable window}"
    fi
    printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%sok%s%s%s%s%s%s\n' \
      "$key" "$US" "$host" "$US" "$mates" "$US" "$provider" "$US" "$acct" "$US" \
      "$h_left" "$US" "$h_reset" "$US" "$h_pace" "$US" "$w_left" "$US" "$w_reset" "$US" "$w_pace" "$US" \
      "$US" "$m_left" "$US" "$m_reset" "$US" "${other:--}" >> "$TMP/rows"
  done < "$dir/present"
done

# Attention: quota-axi's own rows for a provider present on this host, plus
# rows for a provider present elsewhere in the fleet unless they only say it is
# not signed in here (auth_required). A fleet provider that is unmeasurable on
# one host is therefore named, while a mate that simply never signed into a
# provider the laptop uses, and providers nobody uses anywhere, stay quiet.
# A present provider whose credential expired between uses says so plainly.
awk 'NF && !seen[$0]++' "$TMP/present" > "$TMP/fleet-present"
for i in "${!HOST_ORDER[@]}"; do
  host=${HOST_ORDER[$i]}; dir="$TMP/h/$host"
  [ -f "$dir/attention" ] || continue
  while IFS="$US" read -r provider _ kind detail _; do
    [ -n "$provider" ] || continue
    if ! grep -qx -- "$provider" "$dir/present"; then
      grep -qx -- "$provider" "$TMP/fleet-present" || continue
      [ "$kind" != auth_required ] || continue
    fi
    [ "$kind" != stale ] || kind="stale reading"
    printf '%s%s%s%s%s%s%s\n' "$host" "$US" "$provider" "$US" "$kind" "$US" "$detail" >> "$TMP/attention"
  done < "$dir/attention"
  while IFS="$US" read -r provider _ _ _ auth _; do
    [ "$auth" = expired_refreshable ] || continue
    grep -qx -- "$provider" "$dir/present" || continue
    printf '%s%s%s%scredential expired, refreshable%sthe stored sign-in expired between uses and renews on the next use\n' "$host" "$US" "$provider" "$US" "$US" >> "$TMP/attention"
  done < "$dir/providers"
done

# Sort: numeric five-hour rows ascending, then rows with other windows, then
# rows with no window, then failures.
sort -t "$US" -k1,1n -k6,6n -k2,2 "$TMP/rows" > "$TMP/sorted"

# --- render -------------------------------------------------------------------
if [ "$FORMAT" = toon ]; then
  n=$(grep -c . "$TMP/sorted" || true)
  printf 'usage[%s]{host,mates,provider,account,fiveHourLeft,fiveHourResetsAt,fiveHourPace,weekLeft,weekResetsAt,weekPace,read,monthLeft,monthResetsAt,other}:\n' "$n"
  while IFS="$US" read -r _ host mates provider acct hl hr hp wl wr wp read ml mr other; do
    [ -n "$host" ] || continue
    printf '  %s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$(toon_quote "$host")" "$(toon_quote "$mates")" "$(toon_quote "$provider")" "$(toon_quote "$acct")" \
      "$(toon_quote "$hl")" "$(toon_quote "$hr")" "$(toon_quote "$hp")" \
      "$(toon_quote "$wl")" "$(toon_quote "$wr")" "$(toon_quote "$wp")" "$(toon_quote "$read")" \
      "$(toon_quote "$ml")" "$(toon_quote "$mr")" "$(toon_quote "$other")"
  done < "$TMP/sorted"
  m=$(grep -c . "$TMP/attention" || true)
  printf 'attention[%s]{host,provider,kind,detail}:\n' "$m"
  while IFS="$US" read -r host provider kind detail; do
    [ -n "$host" ] || continue
    printf '  %s,%s,%s,%s\n' "$(toon_quote "$host")" "$(toon_quote "$provider")" "$(toon_quote "$kind")" "$(toon_quote "$detail")"
  done < "$TMP/attention"
  exit 0
fi

printf '| host | mates | provider | account | 5h left | 5h resets | 5h pace | week left | week resets | week pace | month left | month resets | other |\n'
printf '| --- | --- | --- | --- | ---: | --- | --- | ---: | --- | --- | ---: | --- | --- |\n'
while IFS="$US" read -r _ host mates provider acct hl hr hp wl wr wp _ ml mr other; do
  [ -n "$host" ] || continue
  hl_cell=$hl; wl_cell=$wl; ml_cell=$ml
  [ "$hl" = - ] || hl_cell="${hl}%"
  [ "$wl" = - ] || wl_cell="${wl}%"
  [ "$ml" = - ] || ml_cell="${ml}%"
  printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$(md_cell "$host")" "$(md_cell "${mates:--}")" "$(md_cell "$provider")" "$(md_cell "$acct")" \
    "$hl_cell" "$(md_cell "$hr")" "$(md_cell "$hp")" "$wl_cell" "$(md_cell "$wr")" "$(md_cell "$wp")" \
    "$ml_cell" "$(md_cell "$mr")" "$(md_cell "$other")"
done < "$TMP/sorted"
printf '\n## attention\n\n'
if [ -s "$TMP/attention" ]; then
  while IFS="$US" read -r host provider kind detail; do
    [ -n "$host" ] || continue
    printf -- '- %s %s %s: %s\n' "$host" "$provider" "$kind" "$detail"
  done < "$TMP/attention"
else
  printf -- '- none\n'
fi
