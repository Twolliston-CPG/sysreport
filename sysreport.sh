#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly VERSION="1.0.0"

THRESHOLD=80
FORMAT="table"
OUTPUT=""
EXIT_CODE=0

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

# Any command that fails unexpectedly lands here. Exit 2 means "the script broke",
# which a monitor can tell apart from exit 1, "a check exceeded the threshold".
# shellcheck disable=SC2329  # called from the ERR trap string below, which shellcheck can't follow
on_err() {
  local code=$1 line=$2 cmd=$3
  trap - ERR
  printf 'ERROR: unexpected failure (exit %s) at line %s: %s\n' "$code" "$line" "$cmd" >&2
  exit 2
}
trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR

usage() {
  cat <<USAGE
$SCRIPT_NAME v$VERSION - report on this machine's health

Usage: $SCRIPT_NAME [OPTIONS]

Options:
  -f, --format FORMAT      table or json (default: table)
  -o, --output FILE        write the report to FILE instead of stdout
  -t, --threshold N        warn above N percent, 1-100 (default: 80)
  -h, --help               show this message

Exit codes: 0 all under threshold, 1 a check exceeded it, 2 bad usage.
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--format)    [[ $# -ge 2 ]] || die "$1 needs a value"; FORMAT="$2"; shift 2 ;;
      -o|--output)    [[ $# -ge 2 ]] || die "$1 needs a value"; OUTPUT="$2"; shift 2 ;;
      -t|--threshold) [[ $# -ge 2 ]] || die "$1 needs a value"; THRESHOLD="$2"; shift 2 ;;
      -h|--help)      usage; exit 0 ;;
      *)              usage >&2; die "unknown option: $1" ;;
    esac
  done

  [[ "$FORMAT" == "table" || "$FORMAT" == "json" ]] \
    || die "--format must be table or json, got: $FORMAT"
  [[ "$THRESHOLD" =~ ^[0-9]+$ && "$THRESHOLD" -ge 1 && "$THRESHOLD" -le 100 ]] \
    || die "--threshold must be an integer from 1 to 100, got: $THRESHOLD"
}

# Host: identity and uptime. Never exits nonzero for a missing piece.
collect_host() {
  HOST_NAME=$(uname -n)
  HOST_KERNEL=$(uname -r)
  # shellcheck source=/dev/null
  HOST_DISTRO=$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-unknown}") \
    || HOST_DISTRO="unknown"
  HOST_UPTIME=$(uptime -p 2>/dev/null || echo "unknown")
  HOST_TIME_UTC=$(date -u +%FT%TZ)
}

# CPU: core count, load averages, and load per core (load1 / cores).
collect_cpu() {
  CPU_CORES=$(nproc)
  read -r CPU_LOAD1 CPU_LOAD5 CPU_LOAD15 _ < /proc/loadavg
  CPU_LOAD_PER_CORE=$(awk -v l="$CPU_LOAD1" -v c="$CPU_CORES" 'BEGIN {printf "%.2f", l / c}')
}

# True if $1 is a number above the threshold. Floats are fine. A non-number
# (df prints "-" for filesystems with no inodes) is "not over", never an error.
over_threshold() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  awk -v v="$1" -v t="$THRESHOLD" 'BEGIN {exit !(v > t)}'
}

# Memory: parsed from /proc/meminfo, sizes in GiB, percent = (total - available) / total.
collect_memory() {
  read -r MEM_TOTAL_GB MEM_USED_GB MEM_AVAIL_GB MEM_PCT SWAP_USED_GB < <(
    awk '/^MemTotal/ {t=$2} /^MemAvailable/ {a=$2} /^SwapTotal/ {st=$2} /^SwapFree/ {sf=$2}
         END {printf "%.1f %.1f %.1f %.1f %.1f\n",
              t/1048576, (t-a)/1048576, a/1048576, (t-a)*100/t, (st-sf)/1048576}' /proc/meminfo)
  MEM_FLAG=0
  if over_threshold "$MEM_PCT"; then MEM_FLAG=1; EXIT_CODE=1; fi
}

# Disk: one "mount|size|used|use%|flag" entry per real filesystem.
DISKS=()
collect_disk() {
  DISKS=()
  local size used pct mount flag
  while read -r size used pct mount; do
    pct=${pct%\%}
    flag=0
    if over_threshold "$pct"; then flag=1; EXIT_CODE=1; fi
    DISKS+=("$mount|$size|$used|$pct|$flag")
  done < <(df -PH --exclude-type=tmpfs --exclude-type=devtmpfs --exclude-type=efivarfs 2>/dev/null |
           awk 'NR>1 {m=$6; for (i=7; i<=NF; i++) m=m" "$i; print $2, $3, $5, m}')
}

# Inodes: same shape, "mount|iuse%|flag". Running out of inodes looks like a full disk (BF-08).
INODES=()
collect_inodes() {
  INODES=()
  local pct mount flag
  while read -r pct mount; do
    pct=${pct%\%}
    flag=0
    if over_threshold "$pct"; then flag=1; EXIT_CODE=1; fi
    INODES+=("$mount|$pct|$flag")
  done < <(df -Pi --exclude-type=tmpfs --exclude-type=devtmpfs --exclude-type=efivarfs 2>/dev/null |
           awk 'NR>1 {m=$6; for (i=7; i<=NF; i++) m=m" "$i; print $5, m}')
}

warn() { printf 'WARN: %s\n' "$*" >&2; }

# Top five processes by a ps sort key (pcpu or pmem), as "pid|cpu|mem|command".
# Reads all of ps's output (awk, not head), so ps never gets SIGPIPE under pipefail.
top_procs() {
  ps -eo pid=,pcpu=,pmem=,comm= --sort="-$1" |
    awk 'NR<=5 {c=$4; for (i=5; i<=NF; i++) c=c" "$i; print $1"|"$2"|"$3"|"c}'
}

PROCS_TOTAL=0; PROCS_ZOMBIES=0; PROCS_TOP_CPU=(); PROCS_TOP_MEM=()
collect_procs() {
  PROCS_TOTAL=$(ps -e --no-headers | wc -l)
  PROCS_ZOMBIES=$(ps -eo stat= | awk '$1 ~ /^Z/ {n++} END {print n+0}')
  mapfile -t PROCS_TOP_CPU < <(top_procs pcpu)
  mapfile -t PROCS_TOP_MEM < <(top_procs pmem)
}

# Network: listening TCP sockets as "address:port|process" ("-" if ss can't see the owner).
LISTENERS=()
collect_net() {
  LISTENERS=()
  if ! command -v ss >/dev/null 2>&1; then warn "ss not found, skipping network"; return 0; fi
  mapfile -t LISTENERS < <(ss -H -tlnp 2>/dev/null | awk '
    {p=$6; if (match(p, /\(\("[^"]+"/)) p=substr(p, RSTART+3, RLENGTH-4); else p="-"
     print $4"|"p}')
}

# systemd: names of failed units. Skipped with a warning when systemd is not running.
FAILED_UNITS=(); SYSTEMD_OK=0
collect_systemd() {
  FAILED_UNITS=()
  if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
    warn "systemd not available, skipping failed-unit check"; return 0
  fi
  SYSTEMD_OK=1
  mapfile -t FAILED_UNITS < <(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')
}

# Logins: "user|tty|since|from".
LOGINS=()
collect_logins() {
  # The login time is 2 or 3 fields depending on locale, so anchor on the optional
  # "(host)" at the end instead of counting from the front.
  mapfile -t LOGINS < <(who | awk '
    {end=NF; f="-"
     if ($NF ~ /^\(.*\)$/) {f=$NF; gsub(/[()]/, "", f); end=NF-1}
     s=$3; for (i=4; i<=end; i++) s=s" "$i
     print $1"|"$2"|"s"|"f}')
}

RED=""; YEL=""; GRN=""; BLD=""; RST=""

# Color only when writing to a terminal, never to --output or a pipe, and never with NO_COLOR.
setup_colors() {
  if [[ -z "$OUTPUT" && -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED=$'\e[31m'; YEL=$'\e[33m'; GRN=$'\e[32m'; BLD=$'\e[1m'; RST=$'\e[0m'
  fi
}

section() { printf '\n%s== %s ==%s\n' "$BLD" "$1" "$RST"; }

# "OVER" or "ok" for a 0/1 flag. The word carries the meaning, color is only a bonus.
status() {
  if [[ "$1" == 1 ]]; then printf '%sOVER%s' "$RED" "$RST"; else printf '%sok%s' "$GRN" "$RST"; fi
}

print_procs() {
  local e pid cpu mem cmd
  printf '    %7s %6s %6s  %s\n' PID CPU% MEM% COMMAND
  for e in "$@"; do
    IFS='|' read -r pid cpu mem cmd <<<"$e"
    printf '    %7s %6s %6s  %s\n' "$pid" "$cpu" "$mem" "$cmd"
  done
}

render_table() {
  local e mount size used pct flag addr proc user tty since from u pct_txt lpc_color=$GRN

  printf '%ssysreport%s  %s  (threshold %s%%)\n' "$BLD" "$RST" "$HOST_TIME_UTC" "$THRESHOLD"

  section "Host"
  printf '  %-9s %s\n' hostname "$HOST_NAME" kernel "$HOST_KERNEL" distro "$HOST_DISTRO" uptime "$HOST_UPTIME"

  section "CPU"
  if awk -v v="$CPU_LOAD_PER_CORE" 'BEGIN {exit !(v > 1)}'; then lpc_color=$YEL; fi
  printf '  %-9s %s\n' cores "$CPU_CORES"
  printf '  %-9s %s  %s  %s   (1/5/15 min)\n' load "$CPU_LOAD1" "$CPU_LOAD5" "$CPU_LOAD15"
  printf '  %-9s %s%s%s per core\n' pressure "$lpc_color" "$CPU_LOAD_PER_CORE" "$RST"

  section "Memory"
  printf '  %-9s %s / %s GiB (%s%%)   %s\n' used "$MEM_USED_GB" "$MEM_TOTAL_GB" "$MEM_PCT" "$(status "$MEM_FLAG")"
  printf '  %-9s %s GiB\n' available "$MEM_AVAIL_GB" 'swap used' "$SWAP_USED_GB"

  section "Disk"
  printf '  %-26s %7s %7s %5s\n' mount size used use
  for e in "${DISKS[@]}"; do
    IFS='|' read -r mount size used pct flag <<<"$e"
    printf '  %-26s %7s %7s %4s%%  %s\n' "$mount" "$size" "$used" "$pct" "$(status "$flag")"
  done

  section "Inodes"
  printf '  %-26s %5s\n' mount use
  for e in "${INODES[@]}"; do
    IFS='|' read -r mount pct flag <<<"$e"
    if [[ "$pct" == "-" ]]; then pct_txt="n/a"; else pct_txt="${pct}%"; fi
    printf '  %-26s %5s  %s\n' "$mount" "$pct_txt" "$(status "$flag")"
  done

  section "Processes"
  if ((PROCS_ZOMBIES > 0)); then u=$RED; else u=""; fi
  printf '  total %s   zombies %s%s%s\n' "$PROCS_TOTAL" "$u" "$PROCS_ZOMBIES" "$RST"
  printf '  top by CPU:\n'; print_procs "${PROCS_TOP_CPU[@]}"
  printf '  top by memory:\n'; print_procs "${PROCS_TOP_MEM[@]}"

  section "Listening TCP"
  if ((${#LISTENERS[@]} == 0)); then printf '  none\n'; else
    for e in "${LISTENERS[@]}"; do
      IFS='|' read -r addr proc <<<"$e"
      printf '  %-28s %s\n' "$addr" "$proc"
    done
    printf '  (process is "-" when it belongs to another user)\n'
  fi

  section "systemd"
  if ((SYSTEMD_OK == 0)); then
    printf '  skipped (systemd not available)\n'
  elif ((${#FAILED_UNITS[@]} == 0)); then
    printf '  %sno failed units%s\n' "$GRN" "$RST"
  else
    for u in "${FAILED_UNITS[@]}"; do printf '  %s%s%s\n' "$RED" "$u" "$RST"; done
  fi

  section "Logins"
  if ((${#LOGINS[@]} == 0)); then printf '  none\n'; else
    for e in "${LOGINS[@]}"; do
      IFS='|' read -r user tty since from <<<"$e"
      printf '  %-10s %-8s %-16s %s\n' "$user" "$tty" "$since" "$from"
    done
  fi

  section "Result"
  if ((EXIT_CODE == 0)); then
    printf '  %sOK%s  everything under %s%%\n' "$GRN" "$RST" "$THRESHOLD"
  else
    printf '  %sOVER THRESHOLD%s  something is above %s%% (exit 1)\n' "$RED" "$RST" "$THRESHOLD"
  fi
}

# Rows on stdin ("a|b|c" per line) -> a JSON array. $1 is a jq object builder over the split
# fields (.[0], .[1], ...). Blank lines are dropped, so an empty bash array becomes [].
rows_json() { jq -nR "[inputs | select(length > 0) | split(\"|\") | $1]"; }

render_json() {
  local disks inodes top_cpu top_mem listeners failed logins
  local mem_over=false sd_ok=false

  disks=$(printf '%s\n' "${DISKS[@]}" | rows_json \
    '{mount: .[0], size: .[1], used: .[2], use_pct: (.[3] | tonumber), over: (.[4] == "1")}')
  inodes=$(printf '%s\n' "${INODES[@]}" | rows_json \
    '{mount: .[0], use_pct: (try (.[1] | tonumber) catch null), over: (.[2] == "1")}')
  top_cpu=$(printf '%s\n' "${PROCS_TOP_CPU[@]}" | rows_json \
    '{pid: (.[0] | tonumber), cpu_pct: (.[1] | tonumber), mem_pct: (.[2] | tonumber), command: (.[3:] | join("|"))}')
  top_mem=$(printf '%s\n' "${PROCS_TOP_MEM[@]}" | rows_json \
    '{pid: (.[0] | tonumber), cpu_pct: (.[1] | tonumber), mem_pct: (.[2] | tonumber), command: (.[3:] | join("|"))}')
  listeners=$(printf '%s\n' "${LISTENERS[@]}" | rows_json \
    '{address: .[0], process: (if .[1] == "-" then null else .[1] end)}')
  logins=$(printf '%s\n' "${LOGINS[@]}" | rows_json \
    '{user: .[0], tty: .[1], since: .[2], from: (if .[3] == "-" then null else .[3] end)}')
  failed=$(printf '%s\n' "${FAILED_UNITS[@]}" | jq -nR '[inputs | select(length > 0)]')

  if ((MEM_FLAG == 1)); then mem_over=true; fi
  if ((SYSTEMD_OK == 1)); then sd_ok=true; fi

  jq -n \
    --arg time "$HOST_TIME_UTC" --arg host "$HOST_NAME" --arg kernel "$HOST_KERNEL" \
    --arg distro "$HOST_DISTRO" --arg uptime "$HOST_UPTIME" \
    --argjson threshold "$THRESHOLD" --argjson exit_code "$EXIT_CODE" \
    --argjson cores "$CPU_CORES" --argjson l1 "$CPU_LOAD1" --argjson l5 "$CPU_LOAD5" \
    --argjson l15 "$CPU_LOAD15" --argjson lpc "$CPU_LOAD_PER_CORE" \
    --argjson mem_total "$MEM_TOTAL_GB" --argjson mem_used "$MEM_USED_GB" \
    --argjson mem_avail "$MEM_AVAIL_GB" --argjson mem_pct "$MEM_PCT" \
    --argjson swap_used "$SWAP_USED_GB" --argjson mem_over "$mem_over" \
    --argjson disks "$disks" --argjson inodes "$inodes" \
    --argjson procs_total "$PROCS_TOTAL" --argjson zombies "$PROCS_ZOMBIES" \
    --argjson top_cpu "$top_cpu" --argjson top_mem "$top_mem" \
    --argjson listeners "$listeners" --argjson failed "$failed" \
    --argjson sd_ok "$sd_ok" --argjson logins "$logins" \
    '{
       timestamp: $time,
       threshold_pct: $threshold,
       ok: ($exit_code == 0),
       host: {name: $host, kernel: $kernel, distro: $distro, uptime: $uptime},
       cpu: {cores: $cores, load: {"1m": $l1, "5m": $l5, "15m": $l15}, load_per_core: $lpc},
       memory: {total_gib: $mem_total, used_gib: $mem_used, available_gib: $mem_avail,
                used_pct: $mem_pct, swap_used_gib: $swap_used, over: $mem_over},
       disks: $disks,
       inodes: $inodes,
       processes: {total: $procs_total, zombies: $zombies, top_cpu: $top_cpu, top_mem: $top_mem},
       network: {listening_tcp: $listeners},
       systemd: {available: $sd_ok, failed_units: $failed},
       logins: $logins
     }'
}

render() {
  case "$FORMAT" in
    table) render_table ;;
    json)  render_json ;;
  esac
}

main() {
  parse_args "$@"
  setup_colors
  [[ -z "$OUTPUT" ]] || { : 2>/dev/null > "$OUTPUT" || die "cannot write to: $OUTPUT"; }
  collect_host; collect_cpu; collect_memory; collect_disk; collect_inodes
  collect_procs; collect_net; collect_systemd; collect_logins
  if [[ -n "$OUTPUT" ]]; then render > "$OUTPUT"; else render; fi
  exit "$EXIT_CODE"
}
main "$@"
