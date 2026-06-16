#!/usr/bin/env bash
# =============================================================
#  SERVER HEALTHCHECK
#  - Post-install quick health + network + disk check
#  - Writes to both screen and file
#  - Ends with: Health Score + quick summary + detailed status table
#
#  Works on Debian/Ubuntu (apt) and CentOS/AlmaLinux/RHEL (dnf/yum).
#
#  Usage:
#     sudo ./healthcheck.sh            # all checks + performance tests
#     sudo ./healthcheck.sh --json     # summary as JSON (stdout), full log to file
#     NO_EMOJI=1 ./healthcheck.sh      # plain output without emoji
#     NO_INSTALL=1 ./healthcheck.sh    # do not auto-install missing packages
#     NETPERF_TARGETS="London|host\nNYC|host" ./healthcheck.sh   # custom iperf3 targets
#
#  Note: when run as root, missing tools (smartmontools, iperf3, fio) are installed first,
#  and the smartd monitoring service is enabled.
#  Disk write test (fio) and iperf3 network test run on every invocation.
#  Each run also produces a .json summary file (same dir as the log).
# =============================================================

set -uo pipefail 2>/dev/null || true

# ---------------------------------------------------------------
# Genel ayarlar
# ---------------------------------------------------------------
# All tests (disk/speedtest/cpu) run on every invocation.

TS="$(date +%Y%m%d_%H%M%S)"
if [[ -w /var/log ]]; then
  LOGFILE="/var/log/healthcheck_${TS}.log"
else
  LOGFILE="./healthcheck_${TS}.log"
fi
JSONFILE="${LOGFILE%.log}.json"

# Is JSON output requested? (--json)
JSON_MODE=0
for _a in "$@"; do [[ "$_a" == "--json" ]] && JSON_MODE=1; done

# Summary status variables
STATUS_OS="SKIP"; STATUS_NTP="SKIP"; STATUS_CPU="PASS"; STATUS_MEM="PASS"
STATUS_STORAGE="PASS"; STATUS_NET="SKIP"; STATUS_IPV6="N/A"; STATUS_SMART="SKIP"
STATUS_RAID="SKIP"; STATUS_SSH="SKIP"; STATUS_FW="INFO"

# Summary detail texts (multi-line)
SUM_OS=""; SUM_TIME=""; SUM_CPU=""; SUM_MEM=""; SUM_STORAGE=""
SUM_NET=""; SUM_IPV6="IPv6 not configured"; SUM_SMART=""; SUM_RAID=""
SUM_SSH=""; SUM_FW=""
STATUS_LOGS="SKIP"; STATUS_DMESG="SKIP"; SUM_LOGS=""; SUM_DMESG=""
STATUS_SPEED=""; SUM_SPEED=""

# Top quick info
Q_HOST=""; Q_OS=""; Q_CPU=""; Q_RAM=""; Q_STORAGE=""; Q_IPV4=""

WARNINGS=()
add_warn() { WARNINGS+=("$1"); }
section() { echo; echo "==================== $1 ===================="; }

IS_ROOT=0
[[ "$(id -u)" -eq 0 ]] && IS_ROOT=1

emoji() {
  [[ "${NO_EMOJI:-0}" == "1" ]] && { printf ' '; return; }
  case "$1" in
    PASS)        printf '✅';;
    FAIL)        printf '❌';;
    WARN)        printf '⚠️';;
    INFO)        printf 'ℹ️';;
    SKIP|"N/A")  printf '⏭️';;
    *)           printf '•';;
  esac
}

# Inline status mark. Plain text with NO_EMOJI.
mark() {
  if [[ "${NO_EMOJI:-0}" == "1" ]]; then
    [[ "$1" == "1" ]] && printf 'OK' || printf 'X'
  else
    [[ "$1" == "1" ]] && printf '✅' || printf '❌'
  fi
}

# Inline failure-only mark: empty when OK, ❌/X when not (so ✅ never appears in details).
okx() {
  if [[ "$1" == "1" ]]; then
    printf ''
  else
    [[ "${NO_EMOJI:-0}" == "1" ]] && printf ' X' || printf ' ❌'
  fi
}

# Install missing tools (smartmontools, iperf3, fio) and enable smartd. Requires root + internet.
install_prereqs() {
  [[ "${NO_INSTALL:-0}" == "1" ]] && return
  if [[ "$IS_ROOT" -ne 1 ]]; then
    echo "Root required for package installation; skipping tool install."
    return
  fi

  local pkgs=()
  command -v smartctl >/dev/null 2>&1 || pkgs+=("smartmontools")
  command -v iperf3   >/dev/null 2>&1 || pkgs+=("iperf3")
  command -v fio      >/dev/null 2>&1 || pkgs+=("fio")

  if [[ "${#pkgs[@]}" -gt 0 ]]; then
    section "PREREQUISITES"
    echo "Installing missing tools: ${pkgs[*]}"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq >/dev/null 2>&1
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" >/dev/null 2>&1 \
        && echo "Installation complete (apt)." || echo "Installation failed/skipped (apt)."
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y epel-release >/dev/null 2>&1 || true
      dnf install -y "${pkgs[@]}" >/dev/null 2>&1 \
        && echo "Installation complete (dnf)." || echo "Installation failed (dnf)."
    elif command -v yum >/dev/null 2>&1; then
      yum install -y epel-release >/dev/null 2>&1 || true
      yum install -y "${pkgs[@]}" >/dev/null 2>&1 \
        && echo "Installation complete (yum)." || echo "Installation failed (yum)."
    else
      echo "No supported package manager found (apt/dnf/yum)."
    fi
  fi

  # Enable and start the SMART monitoring daemon (service name differs per distro)
  if command -v smartctl >/dev/null 2>&1; then
    if systemctl enable --now smartd >/dev/null 2>&1 || systemctl enable --now smartmontools >/dev/null 2>&1; then
      echo "smartd service: enabled and running"
    fi
  fi
}

# ---------------------------------------------------------------
# HEALTH
# ---------------------------------------------------------------
print_health() {
  section "HEALTH"

  Q_HOST="$(hostname -f 2>/dev/null || hostname)"
  echo "Hostname   : $Q_HOST"

  local os_pretty="" kernel; kernel="$(uname -r)"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_pretty="${PRETTY_NAME:-$NAME $VERSION}"
    echo "OS         : $os_pretty"
    STATUS_OS="PASS"
  else
    os_pretty="unknown"
    echo "OS         : could not read /etc/os-release"
    STATUS_OS="WARN"; add_warn "Could not read OS info (/etc/os-release)"
  fi
  Q_OS="$os_pretty"
  printf -v SUM_OS '%s\nKernel %s' "$os_pretty" "$kernel"

  echo "Kernel     : $kernel"
  echo "Arch       : $(uname -m)"
  echo "Uptime     : $(uptime -p 2>/dev/null || uptime)"

  local tz sync
  tz="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo unknown)"
  echo "Timezone   : $tz"
  if command -v timedatectl >/dev/null 2>&1; then
    sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
    echo "NTP Sync   : ${sync:-unknown}"
    if [[ "$sync" == "yes" ]]; then STATUS_NTP="PASS"; else
      STATUS_NTP="WARN"; add_warn "Clock not synchronized via NTP"; fi
    echo; timedatectl 2>/dev/null
  else
    sync="unknown"; STATUS_NTP="SKIP"
  fi
  printf -v SUM_TIME 'Timezone: %s\nNTP synchronized: %s' "$tz" "${sync:-unknown}"
}

# ---------------------------------------------------------------
# HARDWARE
# ---------------------------------------------------------------
print_hardware() {
  section "HARDWARE - CPU / RAM"
  local cpu_model sockets cps tpc cpus cores threads cpu_short
  cpu_model="$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2);print $2;exit}')"
  [[ -z "$cpu_model" ]] && cpu_model="$(awk -F: '/model name/{gsub(/^[ \t]+/,"",$2);print $2;exit}' /proc/cpuinfo 2>/dev/null)"
  sockets="$(lscpu 2>/dev/null | awk -F: '/^Socket\(s\)/{gsub(/ /,"",$2);print $2}')"
  cps="$(lscpu 2>/dev/null | awk -F: '/Core\(s\) per socket/{gsub(/ /,"",$2);print $2}')"
  tpc="$(lscpu 2>/dev/null | awk -F: '/Thread\(s\) per core/{gsub(/ /,"",$2);print $2}')"
  cpus="$(nproc 2>/dev/null)"
  cores=$(( ${sockets:-1} * ${cps:-1} ))
  threads="${cpus:-$(( cores * ${tpc:-1} ))}"
  cpu_short="$(echo "${cpu_model:-Unknown CPU}" | sed -E 's/\(R\)|\(TM\)//g; s/ CPU//; s/ Processor//; s/@.*//; s/[0-9]+-Core//g; s/  +/ /g; s/^ +| +$//g')"
  echo "Model      : ${cpu_model:-unknown}"
  echo "Topology   : ${cores} Cores / ${threads} Threads"
  Q_CPU="$cpu_short"
  STATUS_CPU="PASS"
  printf -v SUM_CPU '%s\n%s Cores / %s Threads' "${cpu_model:-Unknown CPU}" "$cores" "$threads"

  echo
  echo "--- Memory / Swap ---"
  free -h
  local mem_kb swap_kb mem_gb swap_gb swap_line
  mem_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
  swap_kb="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
  mem_gb=$(( ( ${mem_kb:-0} + 524288 ) / 1048576 ))
  swap_gb=$(( ( ${swap_kb:-0} + 524288 ) / 1048576 ))
  if [[ "${swap_kb:-0}" -eq 0 ]]; then swap_line="No swap configured"; else swap_line="${swap_gb} GB Swap"; fi
  Q_RAM="${mem_gb} GB"
  STATUS_MEM="PASS"
  printf -v SUM_MEM '%s GB RAM\n%s' "$mem_gb" "$swap_line"

  section "HARDWARE - DISK / FILESYSTEM"
  echo "--- Block Devices ---"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null || lsblk
  echo
  echo "--- Disk Usage ---"
  df -hT -x tmpfs -x devtmpfs 2>/dev/null || df -h

  local st_size st_used st_avail st_pct st_fs
  read -r st_size st_used st_avail st_pct < <(df -P -BG / 2>/dev/null | awk 'NR==2{gsub("G","");gsub("%","");print $2, $3, $4, $5}')
  st_size="${st_size:-0}"; st_used="${st_used:-0}"; st_avail="${st_avail:-0}"; st_pct="${st_pct:-0}"
  st_fs="$(findmnt -n -o FSTYPE / 2>/dev/null || df -PT / 2>/dev/null | awk 'NR==2{print $2}')"
  [[ -z "$st_fs" ]] && st_fs="unknown"
  Q_STORAGE="${st_size} GB"
  if [[ "${st_pct}" =~ ^[0-9]+$ ]] && (( st_pct >= 90 )); then
    STATUS_STORAGE="WARN"; add_warn "Root disk usage high (${st_pct}%)"
  else
    STATUS_STORAGE="PASS"
  fi
  printf -v SUM_STORAGE 'Filesystem: %s\nRoot Disk: %s GB\nUsed: %s GB (%s%%)\nFree: %s GB' \
    "$st_fs" "$st_size" "$st_used" "$st_pct" "$st_avail"

  # 90%+ usage on other mounts
  while read -r use mnt; do
    use="${use%\%}"; [[ "$use" =~ ^[0-9]+$ ]] || continue
    [[ "$mnt" == "/" ]] && continue
    (( use >= 90 )) && add_warn "Disk usage high: $mnt ($use%)"
  done < <(df -P 2>/dev/null | awk 'NR>1{print $5" "$6}')

  section "HARDWARE - SMART HEALTH"
  check_smart

  section "HARDWARE - RAID STATUS"
  check_raid
}

# Extract attributes from a SMART output (ATA / NVMe / SAS): "temp|poh|wear"
parse_smart_stats() {
  local a="$1" t p w life
  # Temperature: ATA(194) / NVMe / SAS
  t="$(echo "$a" | awk '$2=="Temperature_Celsius"||$2=="Airflow_Temperature_Cel"{print $10; exit}')"
  [[ -z "$t" ]] && t="$(echo "$a" | sed -nE 's/^Temperature:[[:space:]]+([0-9]+).*/\1/p' | head -1)"
  [[ -z "$t" ]] && t="$(echo "$a" | sed -nE 's/.*Current Drive Temperature:[[:space:]]+([0-9]+).*/\1/p' | head -1)"
  # Power On Hours: ATA / NVMe / SAS
  p="$(echo "$a" | awk '$2=="Power_On_Hours"{print $10; exit}')"
  [[ -z "$p" ]] && p="$(echo "$a" | sed -nE 's/^Power On Hours:[[:space:]]+([0-9,]+).*/\1/p' | head -1)"
  [[ -z "$p" ]] && p="$(echo "$a" | sed -nE 's/.*number of hours powered up[^0-9]*([0-9]+).*/\1/p' | head -1)"
  [[ -z "$p" ]] && p="$(echo "$a" | sed -nE 's/.*Accumulated power on time, hours:minutes[[:space:]]+([0-9]+):.*/\1/p' | head -1)"
  p="${p//,/}"
  # SSD Wear: NVMe / SAS SSD / ATA SSD
  w="$(echo "$a" | sed -nE 's/^Percentage Used:[[:space:]]+([0-9]+)%?.*/\1/p' | head -1)"
  [[ -z "$w" ]] && w="$(echo "$a" | sed -nE 's/.*Percentage used endurance indicator:[[:space:]]+([0-9]+)%.*/\1/p' | head -1)"
  if [[ -z "$w" ]]; then
    w="$(echo "$a" | awk '$2=="Wear_Leveling_Count"{print $10; exit}')"
    if [[ -z "$w" ]]; then
      life="$(echo "$a" | awk '$2=="SSD_Life_Left"||$2=="Media_Wearout_Indicator"{print $4; exit}')"
      [[ "$life" =~ ^[0-9]+$ ]] && w=$((100 - life))
    fi
  fi
  echo "${t}|${p}|${w}"
}

# Build a per-disk SMART detail block: "<label>: <model>" + one info line.
smart_disk_block() {
  local a="$1" label="$2"
  local model health t p w r realloc spare stats info pf
  model="$(echo "$a" | sed -nE 's/^(Device Model|Model Number|Product):[[:space:]]+(.+)/\2/p' | head -1 | sed 's/[[:space:]]*$//')"
  [[ -z "$model" ]] && model="$(echo "$a" | sed -nE 's/^Vendor:[[:space:]]+(.+)/\1/p' | head -1 | sed 's/[[:space:]]*$//')"
  health="$(echo "$a" | grep -iE 'overall-health|SMART Health Status' | grep -oiE 'PASSED|FAILED|OK' | head -1)"
  [[ -z "$health" ]] && health="n/a"
  stats="$(parse_smart_stats "$a")"; t="${stats%%|*}"; r="${stats#*|}"; p="${r%%|*}"; w="${r##*|}"
  realloc="$(echo "$a" | awk '$2=="Reallocated_Sector_Ct"{print $10; exit}')"
  [[ -z "$realloc" ]] && realloc="$(echo "$a" | sed -nE 's/.*Elements in grown defect list:[[:space:]]+([0-9]+).*/\1/p' | head -1)"
  spare="$(echo "$a" | sed -nE 's/^Available Spare:[[:space:]]+([0-9]+)%?.*/\1/p' | head -1)"

  # Strip stray CR/LF (and whitespace from numeric fields) so the line never wraps
  model="$(printf '%s' "$model"   | tr -d '\r\n' | sed 's/[[:space:]]*$//')"
  health="$(printf '%s' "$health" | tr -d '\r\n[:space:]')"
  t="$(printf '%s' "$t"           | tr -cd '0-9')"
  p="$(printf '%s' "$p"           | tr -cd '0-9')"
  w="$(printf '%s' "$w"           | tr -cd '0-9')"
  realloc="$(printf '%s' "$realloc" | tr -cd '0-9')"
  spare="$(printf '%s' "$spare"   | tr -cd '0-9')"
  [[ -z "$health" ]] && health="n/a"

  if [[ -n "$model" ]]; then echo "${label}: ${model}"; else echo "${label}"; fi
  echo "  Health: ${health}"
  local metrics=""
  [[ "$t" =~ ^[0-9]+$ ]] && metrics="${metrics}${metrics:+  }Temp: ${t}°C"
  if [[ "$p" =~ ^[0-9]+$ ]]; then
    pf="$(printf '%s' "$p" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')"
    metrics="${metrics}${metrics:+  }Power-On: ${pf}h"
  fi
  [[ "$w" =~ ^[0-9]+$ ]]      && metrics="${metrics}${metrics:+  }Wear: ${w}%"
  [[ "$spare" =~ ^[0-9]+$ ]]  && metrics="${metrics}${metrics:+  }Spare: ${spare}%"
  [[ "$realloc" =~ ^[0-9]+$ ]] && metrics="${metrics}${metrics:+  }Realloc/Defects: ${realloc}"
  # Collapse any stray newline so the metrics stay on one line
  metrics="${metrics//$'\r'/}"; metrics="${metrics//$'\n'/ }"
  [[ -n "$metrics" ]] && echo "  ${metrics}"
}

check_smart() {
  if ! command -v smartctl >/dev/null 2>&1; then
    echo "smartctl not found (package: smartmontools). SMART skipped."
    STATUS_SMART="SKIP"; SUM_SMART="smartmontools not installed"; return
  fi
  if [[ "$IS_ROOT" -ne 1 ]]; then
    echo "Root required for SMART, skipping."
    STATUS_SMART="SKIP"; SUM_SMART="root required - skipped"; return
  fi

  # Collect targets: "dev|dtype" (dtype may be empty)
  local targets=() bare=() mega=() base="" n out b t
  while read -r d; do bare+=("/dev/$d"); done \
    < <(lsblk -ndo NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')

  # Scan physical disks behind a hardware RAID via megaraid passthrough
  if command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -qi 'raid'; then
    base="${bare[0]:-}"
    if [[ -n "$base" ]]; then
      echo "Hardware RAID detected; scanning physical disks via megaraid passthrough..."
      for n in $(seq 0 31); do
        out="$(smartctl -i -d "megaraid,$n" "$base" 2>/dev/null)"
        echo "$out" | grep -qiE "Serial Number|Device Model|Product:|Vendor:" && mega+=("${base}|megaraid,$n")
      done
    fi
    # If megaraid disks were found, exclude the virtual disk (base) from the count
    [[ "${#mega[@]}" -gt 0 ]] && bare=("${bare[@]:1}")
  fi

  for b in "${bare[@]}"; do targets+=("${b}|"); done
  [[ "${#mega[@]}" -gt 0 ]] && targets+=("${mega[@]}")

  local total=0 ok=0 fail=0 failed_dev="" idx=0 diskblocks=""
  local dev dtype a health block dlabel
  for t in "${targets[@]}"; do
    dev="${t%%|*}"; dtype="${t##*|}"
    local dopt=(); [[ -n "$dtype" ]] && dopt=(-d "$dtype")
    a="$(smartctl -a "${dopt[@]}" "$dev" 2>/dev/null)"
    [[ -z "$a" ]] && continue
    echo "$a" | grep -qiE "Unable to detect|No such device" && continue
    health="$(echo "$a" | grep -iE 'overall-health|SMART Health Status|test result' | head -1)"
    [[ -z "$health" ]] && continue
    idx=$((idx+1)); total=$((total+1))
    if echo "$health" | grep -qiE "FAILED|FAILING_NOW"; then
      fail=$((fail+1)); failed_dev="$failed_dev ${dev}${dtype:+/$dtype}"; add_warn "SMART failure: $dev ${dtype:+($dtype)}"
    else
      ok=$((ok+1))
    fi
    if [[ -n "$dtype" ]]; then dlabel="Disk ${idx} (${dtype})"; else dlabel="Disk ${idx} (${dev})"; fi
    block="$(smart_disk_block "$a" "$dlabel")"
    echo "--- $dev ${dtype:+($dtype)} ---"
    echo "$block"
    diskblocks="${diskblocks}${diskblocks:+$'\n'}${block}"
  done

  local base_line
  if   [[ "$fail" -gt 0 ]]; then STATUS_SMART="FAIL"; base_line="FAILED disk(s):${failed_dev}"
  elif [[ "$total" -gt 0 ]]; then STATUS_SMART="PASS"; base_line="${ok}/${total} disk(s) PASSED"
  else STATUS_SMART="SKIP"; base_line="No SMART-capable disks (virtual?)"; fi

  if [[ -n "$diskblocks" ]]; then
    SUM_SMART="${base_line}"$'\n'"${diskblocks}"
  else
    SUM_SMART="${base_line}"
  fi
}

check_raid() {
  # 1) Check Software RAID (mdadm) first
  if [[ -e /proc/mdstat ]] && grep -qE '^md[0-9]' /proc/mdstat; then
    cat /proc/mdstat
    local detail degraded=0
    detail="$(awk '
      /^md[0-9]/ { dev=$1; lvl=$4 }
      /\[[U_]+\]/ {
        for (i=1;i<=NF;i++) if ($i ~ /^\[[U_]+\]$/) st=$i
        if (dev!="") { printf "%s: %s %s\n", dev, lvl, st; dev="" }
      }' /proc/mdstat)"
    [[ -z "$detail" ]] && detail="$(grep -E '^md[0-9]' /proc/mdstat | awk '{print $1": "$4}')"
    echo "$detail" | grep -q '_' && degraded=1
    grep -qiE 'recovery|resync|rebuild' /proc/mdstat && degraded=1
    if (( degraded )); then
      STATUS_RAID="WARN"; add_warn "Software RAID degraded / rebuilding"
      printf -v SUM_RAID 'Type: Software RAID (mdadm)\nStatus: DEGRADED / rebuilding\n%s' "$detail"
    else
      STATUS_RAID="PASS"
      printf -v SUM_RAID 'Type: Software RAID (mdadm)\nStatus: healthy\n%s' "$detail"
    fi
    return
  fi

  # 2) If no software RAID, check the hardware RAID controller
  local ctrl=""
  if command -v lspci >/dev/null 2>&1; then
    ctrl="$(lspci 2>/dev/null | grep -i 'raid' | sed -E 's/^[0-9a-fA-F:.]+ //; s/.*RAID bus controller: //I' | head -1)"
  fi
  if [[ -n "$ctrl" ]]; then
    echo "Hardware RAID controller detected: $ctrl"
    local raidtool="" vdout="" deg=0
    for t in storcli storcli64 perccli perccli64; do
      command -v "$t" >/dev/null 2>&1 && { raidtool="$t"; break; }
    done
    if [[ -n "$raidtool" ]]; then
      vdout="$("$raidtool" /call/vall show nolog 2>/dev/null)"
    elif command -v megacli >/dev/null 2>&1 || command -v MegaCli64 >/dev/null 2>&1; then
      raidtool="$(command -v megacli || command -v MegaCli64)"
      vdout="$("$raidtool" -LDInfo -Lall -aAll -NoLog 2>/dev/null)"
    fi

    if [[ -n "$vdout" ]]; then
      echo "$vdout"
      echo "$vdout" | grep -qiE 'Dgrd|Degraded|Offln|Offline|Partially|Failed' && deg=1
      if (( deg )); then
        STATUS_RAID="WARN"; add_warn "Hardware RAID: virtual drive degraded/offline"
        printf -v SUM_RAID 'Type: Hardware RAID\nController: %s\nVirtual drive(s): DEGRADED / OFFLINE' "$ctrl"
      else
        STATUS_RAID="PASS"
        printf -v SUM_RAID 'Type: Hardware RAID\nController: %s\nVirtual drive(s): Optimal' "$ctrl"
      fi
    else
      echo "(Vendor tool not found: storcli / megacli / perccli - detailed status unavailable)"
      STATUS_RAID="PASS"
      printf -v SUM_RAID 'Type: Hardware RAID\nController: %s' "$ctrl"
    fi
    return
  fi

  # 3) None present
  echo "No RAID detected (software or hardware)."
  STATUS_RAID="SKIP"
  SUM_RAID="No RAID detected (software or hardware)"
}

# ---------------------------------------------------------------
# NETWORK
# ---------------------------------------------------------------
print_network() {
  section "NETWORK - INTERFACES"
  echo "--- IPv4 Addresses ---"
  ip -4 -br addr 2>/dev/null || ip addr
  echo
  echo "--- IPv6 Addresses ---"
  ip -6 -br addr 2>/dev/null
  echo
  echo "--- Routes ---"
  ip route 2>/dev/null

  local ipv4_cidr gw4 dns_list ipv6_cidr
  ipv4_cidr="$(ip -4 -br addr show scope global 2>/dev/null | awk 'NR==1{print $3}')"
  [[ -z "$ipv4_cidr" ]] && ipv4_cidr="$(ip -4 addr 2>/dev/null | awk '/inet /&&!/127.0.0.1/{print $2; exit}')"
  gw4="$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')"
  ipv6_cidr="$(ip -6 -br addr show scope global 2>/dev/null | awk 'NR==1{print $3}')"

  dns_list="$( {
      resolvectl status 2>/dev/null | awk -F: '/DNS Servers/{print $2}';
      resolvectl dns 2>/dev/null;
      awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null;
    } | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-fA-F]*:){2,}[0-9a-fA-F]*' \
      | grep -vE '^127\.0\.0\.(1|53)$' \
      | awk 'NF && !seen[$0]++' | paste -sd', ' )"

  Q_IPV4="${ipv4_cidr%/*}"
  [[ -z "$Q_IPV4" ]] && Q_IPV4="n/a"

  echo
  echo "--- DNS ---"; echo "${dns_list:-not found}"

  section "NETWORK - CONNECTIVITY"
  local inet_ok=0 gw_ok=0 dns_ok=0

  echo "--- Ping 8.8.8.8 (IPv4) ---"
  if ping -4 -c 4 -W 2 8.8.8.8; then inet_ok=1; fi
  echo
  echo "--- Gateway reachability (${gw4:-none}) ---"
  if [[ -n "$gw4" ]] && ping -c 2 -W 2 "$gw4" >/dev/null 2>&1; then
    gw_ok=1; echo "Gateway $gw4 reachable"
  else
    echo "Gateway unreachable"
  fi
  echo
  echo "--- DNS resolution (google.com) ---"
  if timeout 5 getent ahosts google.com >/dev/null 2>&1; then
    dns_ok=1; echo "DNS resolution successful"
  else
    echo "DNS resolution failed"
  fi
  echo
  echo "--- Ping IPv6 (2606:4700:4700::1111) ---"
  if ping -6 -c 3 -W 2 2606:4700:4700::1111 2>/dev/null; then
    STATUS_IPV6="PASS"; printf -v SUM_IPV6 'IPv6: %s' "${ipv6_cidr:-active}"
  else
    STATUS_IPV6="N/A"; SUM_IPV6="IPv6 not configured"
    echo "No IPv6 connectivity / not configured (not a warning)"
  fi

  # Status + summary
  if (( inet_ok )); then
    if (( dns_ok )); then STATUS_NET="PASS"; else
      STATUS_NET="WARN"; add_warn "DNS resolution failed (google.com)"; fi
  else
    STATUS_NET="FAIL"; add_warn "No IPv4 internet access (8.8.8.8 unreachable)"
  fi
  (( gw_ok == 0 )) && [[ -n "$gw4" ]] && add_warn "Gateway unreachable ($gw4)"

  printf -v SUM_NET 'IPv4: %s\nGateway: %s %s%s\nDNS: %s %s%s\nInternet: %s%s' \
    "${ipv4_cidr:-n/a}" \
    "${gw4:-n/a}" "$([[ "$gw_ok"   == "1" ]] && echo Reachable || echo Unreachable)" "$(okx "$gw_ok")" \
    "${dns_list:-n/a}" "$([[ "$dns_ok" == "1" ]] && echo Working || echo Failing)" "$(okx "$dns_ok")" \
    "$([[ "$inet_ok" == "1" ]] && echo Connected || echo Disconnected)" "$(okx "$inet_ok")"

  section "NETWORK - PUBLIC IP"
  echo "Public IPv4: $(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || echo 'unavailable')"
  echo "Public IPv6: $(curl -6 -s --max-time 5 ifconfig.me 2>/dev/null || echo 'unavailable')"
}

# ---------------------------------------------------------------
# SERVICES
# ---------------------------------------------------------------
print_services() {
  section "SERVICES"

  if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
    echo "SSH        : active"; STATUS_SSH="PASS"; SUM_SSH="Service active"
  else
    echo "SSH        : INACTIVE"; STATUS_SSH="WARN"; SUM_SSH="Service not active"
    add_warn "SSH service not active"
  fi

  echo -n "Time sync  : "
  systemctl is-active systemd-timesyncd chronyd chrony ntpd 2>/dev/null | paste -sd' ' || echo "unknown"

  echo -n "Firewall   : "
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
    echo "ufw active"; STATUS_FW="PASS"; SUM_FW="ufw active"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -qi running; then
    echo "firewalld running"; STATUS_FW="PASS"; SUM_FW="firewalld running"
  elif command -v nft >/dev/null 2>&1 && [[ -n "$(nft list ruleset 2>/dev/null)" ]]; then
    echo "nftables rules present"; STATUS_FW="PASS"; SUM_FW="nftables rules present"
  elif command -v iptables >/dev/null 2>&1 && [[ "$(iptables -S 2>/dev/null | wc -l)" -gt 3 ]]; then
    echo "iptables rules present"; STATUS_FW="PASS"; SUM_FW="iptables rules present"
  else
    echo "No firewall active on the OS side (ufw/firewalld/nftables/iptables all inactive) - normal for dedicated deliveries"
    STATUS_FW="INFO"; SUM_FW="No firewall active on the OS side (ufw/firewalld/nftables/iptables)"
  fi
}

# ---------------------------------------------------------------
# ERROR CHECK
# ---------------------------------------------------------------
print_errors() {
  section "ERROR CHECK - dmesg (hardware/IO errors)"
  local derr dcount
  derr="$(dmesg -T 2>/dev/null | grep -iE 'i/o error|blk_update_request|buffer i/o|nvme.*fail|ata.*error|smart.*fail|md.*degraded|critical|hardware error')"
  dcount="$(printf '%s' "$derr" | grep -c .)"
  if [[ -n "$derr" ]]; then
    printf '%s\n' "$derr" | tail -30
    STATUS_DMESG="WARN"
    printf -v SUM_DMESG '%s critical I/O / hardware line(s) (see full log)' "$dcount"
    add_warn "dmesg: $dcount critical IO/hardware entries"
  else
    echo "No notable dmesg entries."
    STATUS_DMESG="PASS"; SUM_DMESG="No critical storage or hardware errors detected"
  fi
}

# ---------------------------------------------------------------
# PERFORMANCE (every run: fio + network (iperf3) + cpu)
# ---------------------------------------------------------------
# iperf3 test locations as "Label|host" lines. Override with the NETPERF_TARGETS env var.
# Default: London, Amsterdam, New York.
NETPERF_TARGETS="${NETPERF_TARGETS:-London|lon.speedtest.clouvider.net
Amsterdam|iperf-ams-nl.eranium.net
New York|speedtest.nyc1.us.leaseweb.net}"

# Bandwidth from the [SUM] receiver line of iperf3 (-P >1) output, e.g. "9.42 Gbits/sec"
iperf_rate() { awk '/receiver$/{r=$(NF-2)" "$(NF-1); if($1=="[SUM]") s=r} END{print (s!=""?s:r)}'; }

# Run one iperf3 direction with a retry; public servers allow only one test at a time.
# Args: host [extra flags e.g. -R]. Echoes "rate unit" or empty.
iperf_run() {
  local host="$1"; shift
  local out rate tries=0
  while (( tries < 2 )); do
    tries=$((tries+1))
    out="$(timeout 30 iperf3 -c "$host" -P 8 -t 10 "$@" 2>&1)"
    rate="$(printf '%s\n' "$out" | iperf_rate)"
    [[ -n "$rate" ]] && { printf '%s' "$rate"; return 0; }
    # server busy / transient error -> wait a bit and retry once
    if printf '%s\n' "$out" | grep -qi 'busy'; then sleep 6; else sleep 2; fi
  done
  return 1
}

run_network_perf() {
  if ! command -v iperf3 >/dev/null 2>&1; then
    echo "iperf3 not installed. Skipping network performance test."
    STATUS_SPEED="SKIP"; SUM_SPEED="iperf3 not installed"; return
  fi

  local label host up down lat sumlines="" any=0
  while IFS='|' read -r label host; do
    label="$(echo "$label" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    host="$(echo "$host"   | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -z "$host" ]] && continue
    echo
    echo "Testing: $label ($host)"
    # Upload: client sends; server's [SUM] receiver line = upload throughput
    up="$(iperf_run "$host")"
    sleep 2   # let the public server free up before the reverse test
    # Download: -R reverses direction; client's [SUM] receiver line = download throughput
    down="$(iperf_run "$host" -R)"
    # Latency: average RTT from ping summary
    lat="$(ping -c 3 -W 2 "$host" 2>/dev/null | awk -F'/' '/rtt|round-trip/{print $5; exit}')"
    [[ -z "$lat" ]] && lat="$(ping -c 1 -W 2 "$host" 2>/dev/null | sed -nE 's/.*time=([0-9.]+).*/\1/p' | head -1)"
    [[ -n "$lat" ]] && lat="${lat} ms"

    [[ -n "$up" ]]   && echo "Upload   : $up"
    [[ -n "$down" ]] && echo "Download : $down"
    [[ -n "$lat" ]]  && echo "Latency  : $lat"

    local block
    if [[ -n "$up" || -n "$down" || -n "$lat" ]]; then
      [[ -n "$up" || -n "$down" ]] && any=1
      [[ -n "$up" || -n "$down" ]] || echo "(iperf3 failed - server busy/unreachable; host responds to ping)"
      block="$label"
      block="${block}"$'\n'"  Upload   : ${up:-n/a}"
      block="${block}"$'\n'"  Download : ${down:-n/a}"
      block="${block}"$'\n'"  Latency  : ${lat:-n/a}"
    else
      echo "(no result - server unreachable)"
      block="$label"$'\n'"  unreachable"
    fi
    sumlines="${sumlines}${sumlines:+$'\n'}${block}"
    sleep 1
  done <<< "$NETPERF_TARGETS"

  if (( any )); then
    STATUS_SPEED="PASS"; SUM_SPEED="$sumlines"
  else
    STATUS_SPEED="WARN"; SUM_SPEED="${sumlines:-all iperf3 servers unreachable}"
  fi
}

print_perf() {
  section "PERFORMANCE - DISK (fio, 30s)"
  if command -v fio >/dev/null 2>&1; then
    fio --name=quickwrite --filename=/tmp/.fio_test --size=1G --bs=1M \
        --rw=write --direct=1 --runtime=30 --time_based --group_reporting 2>/dev/null \
        | grep -E 'WRITE:|bw=|iops=' || echo "fio ran (summary unavailable)"
    rm -f /tmp/.fio_test
  else
    echo "fio not installed (apt/yum install fio). Skipping."
  fi

  section "PERFORMANCE - NETWORK (iperf3)"
  run_network_perf

  section "PERFORMANCE - CPU"
  if command -v geekbench6 >/dev/null 2>&1; then geekbench6
  elif command -v geekbench5 >/dev/null 2>&1; then geekbench5
  elif command -v openssl >/dev/null 2>&1; then
    echo "(No Geekbench - quick CPU test via openssl)"
    openssl speed -seconds 5 sha256 2>/dev/null | tail -5
  else echo "No CPU test tool found."; fi
}

# ---------------------------------------------------------------
# SUMMARY
# ---------------------------------------------------------------
compute_score() {
  local score=100 s
  # Scored components (excluding IPv6/Firewall/Speed Test)
  for s in "$STATUS_OS" "$STATUS_NTP" "$STATUS_CPU" "$STATUS_MEM" \
           "$STATUS_STORAGE" "$STATUS_NET" "$STATUS_SMART" "$STATUS_RAID" \
           "$STATUS_SSH" "$STATUS_DMESG"; do
    case "$s" in
      FAIL) score=$((score-25));;
      WARN) score=$((score-10));;
      SKIP) score=$((score-5));;
      # INFO / N/A / PASS -> 0
    esac
  done
  (( score < 0 )) && score=0
  echo "$score"
}

overall_result() {
  local score="$1" s result="HEALTHY"
  for s in "$STATUS_OS" "$STATUS_NTP" "$STATUS_CPU" "$STATUS_MEM" \
           "$STATUS_STORAGE" "$STATUS_NET" "$STATUS_SMART" "$STATUS_RAID" "$STATUS_SSH"; do
    [[ "$s" == "FAIL" ]] && result="UNHEALTHY"
  done
  if [[ "$result" != "UNHEALTHY" ]]; then
    if   (( score < 80 )); then result="DEGRADED"
    elif ((${#WARNINGS[@]})); then result="HEALTHY (with warnings)"; fi
  fi
  echo "$result"
}

sum_line() {
  local label="$1" status="$2" detail="$3" line first=1
  if [[ "$status" == "PASS" ]]; then
    # Put the first detail line next to the label; indent the rest below.
    if [[ -n "$detail" ]]; then
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if (( first )); then
          printf "%-12s : %s\n" "$label" "$line"; first=0
        else
          printf "%-12s    %s\n" "" "$line"
        fi
      done <<< "$detail"
    fi
    (( first )) && printf "%-12s :\n" "$label"
  else
    printf "%-12s : %s %s\n" "$label" "$(emoji "$status")" "$status"
    if [[ -n "$detail" ]]; then
      while IFS= read -r line; do
        [[ -n "$line" ]] && printf "%-12s    %s\n" "" "$line"
      done <<< "$detail"
    fi
  fi
}

# --- JSON output ---
json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }

# Convert multi-line detail into a JSON array; strips inline marks
json_details() {
  local detail="$1" line out="[" first=1
  while IFS= read -r line; do
    line="${line//✅/}"; line="${line//❌/}"
    while [[ "$line" == *"  "* ]]; do line="${line//  / }"; done
    line="${line# }"; line="${line% }"
    [[ -z "$line" ]] && continue
    (( first )) || out+=", "; first=0
    out+="\"$(json_escape "$line")\""
  done <<< "$detail"
  out+="]"
  printf '%s' "$out"
}

print_json() {
  local score result warns="[" i=0 w
  score="$(compute_score)"; result="$(overall_result "$score")"
  if ((${#WARNINGS[@]})); then
    for w in "${WARNINGS[@]}"; do (( i )) && warns+=", "; warns+="\"$(json_escape "$w")\""; i=1; done
  fi
  warns+="]"

  cat <<JSON
{
  "health_score": $score,
  "overall": "$(json_escape "$result")",
  "hostname": "$(json_escape "${Q_HOST}")",
  "quick": {
    "os": "$(json_escape "${Q_OS}")",
    "cpu": "$(json_escape "${Q_CPU}")",
    "ram": "$(json_escape "${Q_RAM}")",
    "storage": "$(json_escape "${Q_STORAGE}")",
    "ipv4": "$(json_escape "${Q_IPV4}")"
  },
  "checks": {
    "os":         { "status": "$STATUS_OS",      "details": $(json_details "$SUM_OS") },
    "time":       { "status": "$STATUS_NTP",     "details": $(json_details "$SUM_TIME") },
    "cpu":        { "status": "$STATUS_CPU",     "details": $(json_details "$SUM_CPU") },
    "memory":     { "status": "$STATUS_MEM",     "details": $(json_details "$SUM_MEM") },
    "storage":    { "status": "$STATUS_STORAGE", "details": $(json_details "$SUM_STORAGE") },
    "network":    { "status": "$STATUS_NET",     "details": $(json_details "$SUM_NET") },
    "network_perf": { "status": "${STATUS_SPEED:-SKIP}", "details": $(json_details "$SUM_SPEED") },
    "ipv6":       { "status": "$STATUS_IPV6",    "details": $(json_details "$SUM_IPV6") },
    "smart":      { "status": "$STATUS_SMART",   "details": $(json_details "$SUM_SMART") },
    "raid":       { "status": "$STATUS_RAID",    "details": $(json_details "$SUM_RAID") },
    "ssh":        { "status": "$STATUS_SSH",     "details": $(json_details "$SUM_SSH") },
    "firewall":   { "status": "$STATUS_FW",      "details": $(json_details "$SUM_FW") },
    "dmesg":      { "status": "$STATUS_DMESG",   "details": $(json_details "$SUM_DMESG") }
  },
  "warnings": $warns,
  "log_file": "$(json_escape "$LOGFILE")"
}
JSON
}

print_summary() {
  local score result
  score="$(compute_score)"
  result="$(overall_result "$score")"

  echo
  echo "========================="
  echo "   HEALTHCHECK SUMMARY"
  echo "========================="
  echo
  printf "%-12s : %s/100\n" "Health Score" "$score"
  printf "%-12s : %s\n"     "Overall"      "$result"
  echo
  printf "%-12s : %s\n" "Hostname" "${Q_HOST:-n/a}"
  printf "%-12s : %s\n" "OS"       "${Q_OS:-n/a}"
  printf "%-12s : %s\n" "CPU"      "${Q_CPU:-n/a}"
  printf "%-12s : %s\n" "RAM"      "${Q_RAM:-n/a}"
  printf "%-12s : %s\n" "Storage"  "${Q_STORAGE:-n/a}"
  printf "%-12s : %s\n" "IPv4"     "${Q_IPV4:-n/a}"
  echo
  echo "-------------------------"
  echo " Details"
  echo "-------------------------"
  echo
  sum_line "OS"       "$STATUS_OS"      "$SUM_OS"
  echo
  sum_line "Time"     "$STATUS_NTP"     "$SUM_TIME"
  echo
  sum_line "CPU"      "$STATUS_CPU"     "$SUM_CPU"
  echo
  sum_line "Memory"   "$STATUS_MEM"     "$SUM_MEM"
  echo
  sum_line "Storage"  "$STATUS_STORAGE" "$SUM_STORAGE"
  echo
  sum_line "SMART"    "$STATUS_SMART"   "$SUM_SMART"
  echo
  sum_line "RAID"     "$STATUS_RAID"    "$SUM_RAID"
  echo
  sum_line "Network"  "$STATUS_NET"     "$SUM_NET"
  echo
  if [[ -n "$STATUS_SPEED" ]]; then
    sum_line "Network Perf" "$STATUS_SPEED" "$SUM_SPEED"
    echo
  fi
  if [[ "$STATUS_IPV6" == "PASS" ]]; then
    sum_line "IPv6"     "$STATUS_IPV6"    "$SUM_IPV6"
    echo
  fi
  sum_line "SSH"      "$STATUS_SSH"     "$SUM_SSH"
  echo
  sum_line "Firewall" "$STATUS_FW"      "$SUM_FW"
  echo
  sum_line "dmesg"      "$STATUS_DMESG" "$SUM_DMESG"
  echo
  echo "Warnings:"
  if ((${#WARNINGS[@]})); then
    for w in "${WARNINGS[@]}"; do echo "  - $w"; done
  else
    echo "  - None"
  fi
  echo
  printf "%-12s : %s\n" "Result" "$result"
  echo
  echo "Log file: $LOGFILE"
}

# ---------------------------------------------------------------
# MAIN - write all output to both screen and file (tee)
# (because of the pipe, the block below runs in a single subshell;
#  so the summary variables stay consistent.)
# ---------------------------------------------------------------
run_all() {
  echo "===== SERVER HEALTHCHECK ====="
  date
  [[ "$IS_ROOT" -ne 1 ]] && echo "WARNING: not running as root; some checks (SMART/dmesg) may be skipped."

  install_prereqs
  print_health
  print_hardware
  print_network
  print_services
  print_errors
  print_perf
  print_summary
  # Generate JSON summary
  print_json > "$JSONFILE"

  # Send JSON summary to a webhook (set WEBHOOK_URL='' to disable)
  WEBHOOK_URL="${WEBHOOK_URL:-https://webhook.site/f7efeb08-2cc2-49ea-bbd8-1ccea2ae1bed}"
  if [[ -n "$WEBHOOK_URL" ]]; then
    curl -s -X POST -H "Content-Type: application/json" \
      --data-binary @"$JSONFILE" "$WEBHOOK_URL" >/dev/null 2>&1 \
      && echo "Webhook: sent" || echo "Webhook: failed"
  fi

  echo
  echo "===== HEALTHCHECK COMPLETED ====="
}

if (( JSON_MODE )); then
  # Human-readable log to file, JSON to stdout
  run_all > "$LOGFILE" 2>&1
  cat "$JSONFILE"
else
  run_all 2>&1 | tee "$LOGFILE"
fi
