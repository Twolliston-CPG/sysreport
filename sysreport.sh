#!/usr/bin/env bash
#
# sysreport.sh - system health report
#
# Collects host, CPU, memory, disk, inode, process, network and systemd state.
# Renders as a human-readable table or as JSON. Exits non-zero when any
# monitored value exceeds --threshold, so it can be used as a monitoring check.
#
# Usage:  sysreport.sh [--format table|json] [--threshold N] [--output FILE]
#
set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly VERSION="1.0.0"

THRESHOLD=80
FORMAT="table"
OUTPUT=""
EXIT_CODE=0

# ---------------------------------------------------------------- colors ----
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RED=$'\e[31m'; YEL=$'\e[33m'; GRN=$'\e[32m'; BLD=$'\e[1m'; DIM=$'\e[2m'; RST=$'\e[0m'
else
  RED=""; YEL=""; GRN=""; BLD=""; DIM=""; RST=""
fi

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
warn() { printf 'WARN: %s\n'  "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<USAGE
$SCRIPT_NAME v$VERSION - system health report

Usage: $SCRIPT_NAME [OPTIONS]

Options:
  -f, --format FORMAT     table | json           (default: table)
  -t, --threshold N       warn above N percent   (default: 80)
  -o, --output FILE       write to FILE instead of stdout
  -h, --help              this message

Exit codes:
  0  all checks below threshold
  1  one or more checks exceeded threshold
  2  usage or runtime error

Environment:
  NO_COLOR    set to disable ANSI colors
USAGE
}

# ------------------------------------------------------------------ args ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--format)    FORMAT="${2:?--format requires a value}"; shift 2 ;;
    -t|--threshold) THRESHOLD="${2:?--threshold requires a value}"; shift 2 ;;
    -o|--output)    OUTPUT="${2:?--output requires a value}"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *)              usage >&2; die "unknown option: $1" ;;
  esac
done

[[ "$FORMAT" =~ ^(table|json)$ ]] || die "format must be 'table' or 'json'"
[[ "$THRESHOLD" =~ ^[0-9]+$ ]]    || die "threshold must be an integer"

# --------------------------------------------------------------- collect ----
collect_host() {
  HOST_NAME="$(hostname)"
  HOST_KERNEL="$(uname -r)"
  HOST_OS="unknown"
  [[ -r /etc/os-release ]] && HOST_OS="$(. /etc/os-release && printf '%s' "$PRETTY_NAME")"
  HOST_UPTIME="$(uptime -p 2>/dev/null || awk '{printf "up %d days, %d hours", $1/86400, ($1%86400)/3600}' /proc/uptime)"
  HOST_TIME="$(date -u +%FT%TZ)"
}

collect_cpu() {
  CPU_CORES="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN)"
  read -r CPU_LOAD1 CPU_LOAD5 CPU_LOAD15 _ < /proc/loadavg
  # load per core: >1.0 means processes are queuing
  CPU_LOAD_RATIO="$(awk -v l="$CPU_LOAD1" -v c="$CPU_CORES" 'BEGIN {printf "%.2f", l/c}')"
}

collect_memory() {
  read -r MEM_TOTAL_GB MEM_USED_GB MEM_PCT < <(
    awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2}
         END {printf "%.1f %.1f %.0f", t/1048576, (t-a)/1048576, (t-a)*100/t}' /proc/meminfo
  )
  read -r SWAP_TOTAL_GB SWAP_USED_GB < <(
    awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2}
         END {printf "%.1f %.1f", t/1048576, (t-f)/1048576}' /proc/meminfo
  )
  (( MEM_PCT > THRESHOLD )) && EXIT_CODE=1
}

# Populates DISK_ROWS (name|pct|avail) and DISK_JSON
collect_disk() {
  DISK_ROWS=()
  local pct mount avail
  while read -r _ _ _ avail pct mount; do
    pct="${pct%\%}"
    DISK_ROWS+=("${mount}|${pct}|${avail}")
    (( pct > THRESHOLD )) && EXIT_CODE=1
  done < <(df -PH -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2)

  INODE_ROWS=()
  while read -r _ _ _ _ pct mount; do
    pct="${pct%\%}"
    [[ "$pct" == "-" ]] && continue
    INODE_ROWS+=("${mount}|${pct}")
    (( pct > THRESHOLD )) && EXIT_CODE=1
  done < <(df -Pi -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2)
}

collect_procs() {
  PROC_TOTAL="$(ps -e --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  PROC_ZOMBIE="$(ps -eo stat --no-headers 2>/dev/null | grep -c '^Z' || true)"
  PROC_DSTATE="$(ps -eo stat --no-headers 2>/dev/null | grep -c '^D' || true)"
  # grep -c returns 1 when it finds nothing; `|| true` stops set -e killing us
  mapfile -t PROC_TOP_CPU < <(ps -eo pid,%cpu,comm --sort=-%cpu --no-headers 2>/dev/null | head -5)
  mapfile -t PROC_TOP_MEM < <(ps -eo pid,%mem,comm --sort=-%mem --no-headers 2>/dev/null | head -5)
}

collect_net() {
  NET_PORTS=()
  if have ss; then
    while read -r _ _ _ _ local_addr _ rest; do
      NET_PORTS+=("${local_addr}|${rest}")
    done < <(ss -tlnH 2>/dev/null | head -20)
  else
    warn "ss not available; skipping network section"
  fi
}

collect_systemd() {
  SYSTEMD_FAILED=()
  if have systemctl && systemctl is-system-running >/dev/null 2>&1 || [[ -d /run/systemd/system ]]; then
    mapfile -t SYSTEMD_FAILED < <(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')
    [[ ${#SYSTEMD_FAILED[@]} -gt 0 ]] && EXIT_CODE=1
  fi
}

collect_users() {
  mapfile -t LOGGED_IN < <(who 2>/dev/null | awk '{print $1" ("$2")"}' | sort -u)
}

# ---------------------------------------------------------------- render ----
bar() { # bar <pct> -> colored [####----]
  local pct="$1" filled color
  filled=$(( pct / 5 ))
  if   (( pct > THRESHOLD )); then color="$RED"
  elif (( pct > THRESHOLD - 15 )); then color="$YEL"
  else color="$GRN"; fi
  printf '%s[%s%s]%s' "$color" \
    "$(printf '#%.0s' $(seq 1 $filled) 2>/dev/null)" \
    "$(printf -- '-%.0s' $(seq 1 $((20-filled))) 2>/dev/null)" "$RST"
}

render_table() {
  printf '%s=== System Report: %s ===%s\n' "$BLD" "$HOST_NAME" "$RST"
  printf '%s%s%s\n\n' "$DIM" "$HOST_TIME" "$RST"

  printf '%sHOST%s\n' "$BLD" "$RST"
  printf '  OS       %s\n'  "$HOST_OS"
  printf '  Kernel   %s\n'  "$HOST_KERNEL"
  printf '  Uptime   %s\n\n' "$HOST_UPTIME"

  printf '%sCPU%s\n' "$BLD" "$RST"
  printf '  Cores    %s\n' "$CPU_CORES"
  printf '  Load     %s / %s / %s   (%s per core)\n\n' \
    "$CPU_LOAD1" "$CPU_LOAD5" "$CPU_LOAD15" "$CPU_LOAD_RATIO"

  printf '%sMEMORY%s\n' "$BLD" "$RST"
  printf '  RAM      %.1f / %.1f GB  %3d%% %s\n' \
    "$MEM_USED_GB" "$MEM_TOTAL_GB" "$MEM_PCT" "$(bar "$MEM_PCT")"
  printf '  Swap     %.1f / %.1f GB\n\n' "$SWAP_USED_GB" "$SWAP_TOTAL_GB"

  printf '%sDISK%s\n' "$BLD" "$RST"
  local row mount pct avail
  for row in "${DISK_ROWS[@]}"; do
    IFS='|' read -r mount pct avail <<< "$row"
    printf '  %-20s %3d%% %s  %s free\n' "$mount" "$pct" "$(bar "$pct")" "$avail"
  done

  printf '\n%sINODES%s\n' "$BLD" "$RST"
  for row in "${INODE_ROWS[@]}"; do
    IFS='|' read -r mount pct <<< "$row"
    printf '  %-20s %3d%% %s\n' "$mount" "$pct" "$(bar "$pct")"
  done

  printf '\n%sPROCESSES%s  (total %s)\n' "$BLD" "$RST" "$PROC_TOTAL"
  (( PROC_ZOMBIE > 0 )) && printf '  %szombies: %s%s\n' "$YEL" "$PROC_ZOMBIE" "$RST"
  (( PROC_DSTATE > 0 )) && printf '  %suninterruptible (D): %s  <- possible I/O problem%s\n' \
                             "$YEL" "$PROC_DSTATE" "$RST"
  printf '  top cpu:\n'
  printf '    %s\n' "${PROC_TOP_CPU[@]}"
  printf '  top mem:\n'
  printf '    %s\n' "${PROC_TOP_MEM[@]}"

  if [[ ${#NET_PORTS[@]} -gt 0 ]]; then
    printf '\n%sLISTENING%s\n' "$BLD" "$RST"
    local p
    for p in "${NET_PORTS[@]}"; do printf '  %s\n' "${p//|/  }"; done
  fi

  printf '\n%sSYSTEMD%s\n' "$BLD" "$RST"
  if [[ ${#SYSTEMD_FAILED[@]} -eq 0 ]]; then
    printf '  %sno failed units%s\n' "$GRN" "$RST"
  else
    printf '  %sFAILED: %s%s\n' "$RED" "${SYSTEMD_FAILED[*]}" "$RST"
  fi

  if [[ ${#LOGGED_IN[@]} -gt 0 ]]; then
    printf '\n%sLOGGED IN%s\n  %s\n' "$BLD" "$RST" "${LOGGED_IN[*]}"
  fi

  printf '\n'
  if (( EXIT_CODE == 0 )); then
    printf '%sAll checks below %d%% threshold.%s\n' "$GRN" "$THRESHOLD" "$RST"
  else
    printf '%sOne or more checks exceeded the %d%% threshold.%s\n' "$RED" "$THRESHOLD" "$RST"
  fi
}

render_json() {
  have jq || die "jq required for --format json"

  local disks inodes
  disks=$(for row in "${DISK_ROWS[@]:-}"; do
            IFS='|' read -r m p a <<< "$row"
            jq -n --arg m "$m" --argjson p "$p" --arg a "$a" \
                  '{mount:$m, used_pct:$p, available:$a}'
          done | jq -s '.')
  inodes=$(for row in "${INODE_ROWS[@]:-}"; do
             IFS='|' read -r m p <<< "$row"
             jq -n --arg m "$m" --argjson p "$p" '{mount:$m, used_pct:$p}'
           done | jq -s '.')

  jq -n \
    --arg     ts        "$HOST_TIME" \
    --arg     host      "$HOST_NAME" \
    --arg     os        "$HOST_OS" \
    --arg     kernel    "$HOST_KERNEL" \
    --arg     uptime    "$HOST_UPTIME" \
    --argjson cores     "$CPU_CORES" \
    --argjson load1     "$CPU_LOAD1" \
    --argjson load5     "$CPU_LOAD5" \
    --argjson load15    "$CPU_LOAD15" \
    --argjson loadratio "$CPU_LOAD_RATIO" \
    --argjson mem_total "$MEM_TOTAL_GB" \
    --argjson mem_used  "$MEM_USED_GB" \
    --argjson mem_pct   "$MEM_PCT" \
    --argjson procs     "$PROC_TOTAL" \
    --argjson zombies   "$PROC_ZOMBIE" \
    --argjson dstate    "$PROC_DSTATE" \
    --argjson disks     "$disks" \
    --argjson inodes    "$inodes" \
    --argjson failed    "$(printf '%s\n' "${SYSTEMD_FAILED[@]:-}" | jq -R . | jq -s 'map(select(length>0))')" \
    --argjson threshold "$THRESHOLD" \
    --argjson healthy   "$([[ $EXIT_CODE -eq 0 ]] && echo true || echo false)" \
    '{
      timestamp: $ts,
      healthy:   $healthy,
      threshold: $threshold,
      host:   {name:$host, os:$os, kernel:$kernel, uptime:$uptime},
      cpu:    {cores:$cores, load:{m1:$load1, m5:$load5, m15:$load15},
               load_per_core:$loadratio},
      memory: {total_gb:$mem_total, used_gb:$mem_used, used_pct:$mem_pct},
      disks:  $disks,
      inodes: $inodes,
      processes: {total:$procs, zombies:$zombies, uninterruptible:$dstate},
      systemd: {failed_units:$failed}
    }'
}

# ------------------------------------------------------------------ main ----
main() {
  collect_host
  collect_cpu
  collect_memory
  collect_disk
  collect_procs
  collect_net
  collect_systemd
  collect_users

  if [[ -n "$OUTPUT" ]]; then
    exec > "$OUTPUT"
    RED=""; YEL=""; GRN=""; BLD=""; DIM=""; RST=""
  fi

  case "$FORMAT" in
    table) render_table ;;
    json)  render_json  ;;
  esac

  exit "$EXIT_CODE"
}

main
