#!/usr/bin/env bash
# =============================================================
#  SERVER HEALTHCHECK
#  - Post-install quick health + network + disk check
#  - Writes to both screen and file
#  - Ends with: Health Score + quick summary + detailed status table
#
#  Usage:
#     sudo ./healthcheck.sh            # all checks + performance tests
#     sudo ./healthcheck.sh --json     # summary as JSON (stdout), full log to file
#     NO_EMOJI=1 ./healthcheck.sh      # plain output without emoji
#     NO_INSTALL=1 ./healthcheck.sh    # do not auto-install missing packages
#
#  Note: when run as root, missing tools (smartmontools, speedtest-cli, fio) are installed first.
#  Disk write test (fio) and speedtest run on every invocation.
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

# Install missing tools (smartmontools first, then speedtest-cli). Requires root + internet.
install_prereqs() {
  [[ "${NO_INSTALL:-0}" == "1" ]] && return
  if [[ "$IS_ROOT" -ne 1 ]]; then
    echo "Root required for package installation; skipping tool install."
    return
  fi

  local pkgs=()
  command -v smartctl >/dev/null 2>&1 || pkgs+=("smartmontools")
  command -v curl >/dev/null 2>&1 || pkgs+=("curl")
  if ! command -v speedtest-cli >/dev/null 2>&1 && ! command -v speedtest >/dev/null 2>&1; then
    pkgs+=("speedtest-cli")
  fi
  command -v fio >/dev/null 2>&1 || pkgs+=("fio")
  [[ "${#pkgs[@]}" -eq 0 ]] && return

  section "PREREQUISITES"
  echo "Installing missing tools: ${pkgs[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" >/dev/null 2>&1 \
      && echo "Installation complete (apt)." || echo "Installation failed/skipped (apt)."
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${pkgs[@]}" >/dev/null 2>&1 \
      && echo "Installation complete (dnf)." || echo "Installation failed (dnf - speedtest-cli may need EPEL)."
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${pkgs[@]}" >/dev/null 2>&1 \
      && echo "Installation complete (yum)." || echo "Installation failed (yum - speedtest-cli may need EPEL)."
  else
    echo "No supported package manager found (apt/dnf/yum)."
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

  local total=0 ok=0 fail=0 failed_dev="" first=1
  local dev dtype a health stats rest s_temp="" s_poh="" s_wear=""
  for t in "${targets[@]}"; do
    dev="${t%%|*}"; dtype="${t##*|}"
    local dopt=(); [[ -n "$dtype" ]] && dopt=(-d "$dtype")
    a="$(smartctl -a "${dopt[@]}" "$dev" 2>/dev/null)"
    [[ -z "$a" ]] && continue
    echo "$a" | grep -qiE "Unable to detect|No such device" && continue
    health="$(echo "$a" | grep -iE 'overall-health|SMART Health Status|test result' | head -1)"
    [[ -z "$health" ]] && continue
    echo "--- $dev ${dtype:+($dtype)} ---"
    echo "$health"
    total=$((total+1))
    if echo "$health" | grep -qiE "FAILED|FAILING_NOW"; then
      fail=$((fail+1)); failed_dev="$failed_dev ${dev}${dtype:+/$dtype}"; add_warn "SMART failure: $dev ${dtype:+($dtype)}"
    else
      ok=$((ok+1))
    fi
    if [[ "$first" -eq 1 ]]; then
      stats="$(parse_smart_stats "$a")"
      s_temp="${stats%%|*}"; rest="${stats#*|}"
      s_poh="${rest%%|*}"; s_wear="${rest##*|}"
      first=0
    fi
  done

  local base_line extra=""
  if   [[ "$fail" -gt 0 ]]; then STATUS_SMART="FAIL"; base_line="FAILED disk(s):${failed_dev}"
  elif [[ "$total" -gt 0 ]]; then STATUS_SMART="PASS"; base_line="${ok}/${total} disk(s) PASSED"
  else STATUS_SMART="SKIP"; base_line="No SMART-capable disks (virtual?)"; fi

  [[ "$s_temp" =~ ^[0-9]+$ ]] && extra="${extra}"$'\n'"Temperature: ${s_temp}°C"
  if [[ "$s_poh" =~ ^[0-9]+$ ]]; then
    local poh_fmt; poh_fmt="$(printf '%s' "$s_poh" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')"
    extra="${extra}"$'\n'"Power On Hours: ${poh_fmt}"
  fi
  [[ "$s_wear" =~ ^[0-9]+$ ]] && extra="${extra}"$'\n'"SSD Wear: ${s_wear}%"

  SUM_SMART="${base_line}${extra}"
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

  printf -v SUM_NET 'IPv4: %s\nGateway: %s %s %s\nDNS: %s %s %s\nInternet: %s %s' \
    "${ipv4_cidr:-n/a}" \
    "${gw4:-n/a}" "$(mark "$gw_ok")"   "$([[ "$gw_ok"   == "1" ]] && echo Reachable || echo Unreachable)" \
    "${dns_list:-n/a}" "$(mark "$dns_ok")" "$([[ "$dns_ok" == "1" ]] && echo Working   || echo Failing)" \
    "$(mark "$inet_ok")" "$([[ "$inet_ok" == "1" ]] && echo Connected || echo Disconnected)"

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
  systemctl is-active systemd-timesyncd chronyd chrony ntpd 2>/dev/null | paste -sd' ' || echo "bilinmiyor"

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
    echo "no active firewall detected (normal for dedicated deliveries)"
    STATUS_FW="INFO"; SUM_FW="No active firewall detected"
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
# PERFORMANCE (every run: fio + speedtest + cpu)
# ---------------------------------------------------------------
# Format an Mbps value as Mbps/Gbps
fmt_speed() { awk -v v="$1" 'BEGIN{ if(v>=1000) printf "%.2f Gbps", v/1000; else printf "%.2f Mbps", v }'; }

# Cloudflare-based speed test (needs only curl, reliable, provides location)
# Output: "DL_Mbps UL_Mbps PING_ms Location" or empty + return 1 on failure
cf_speedtest() {
  command -v curl >/dev/null 2>&1 || return 1
  local meta down up lat city colo
  local DL_BYTES=500000000 UL_BYTES=100000000   # ~500MB download, ~100MB upload
  meta="$(curl -s --max-time 10 https://speed.cloudflare.com/meta 2>/dev/null)"
  down="$(curl -s -o /dev/null --max-time 20 -w '%{speed_download}' \
          "https://speed.cloudflare.com/__down?bytes=${DL_BYTES}" 2>/dev/null)"
  # 'down' may be scientific notation (e.g. 1.18e+09) on fast links; let awk parse it
  awk -v d="${down:-0}" 'BEGIN{ exit !(d+0 > 100000) }' || return 1   # fail if not > ~0.8 Mbps
  lat="$(curl -s -o /dev/null --max-time 10 -w '%{time_connect}' \
         'https://speed.cloudflare.com/__down?bytes=0' 2>/dev/null)"
  up="$(head -c "$UL_BYTES" /dev/zero 2>/dev/null | curl -s -o /dev/null --max-time 20 \
        -w '%{speed_upload}' --data-binary @- 'https://speed.cloudflare.com/__up' 2>/dev/null)"
  city="$(printf '%s' "$meta" | grep -oE '"city":"[^"]*"' | head -1 | sed 's/.*://; s/"//g')"
  colo="$(printf '%s' "$meta" | grep -oE '"colo":"[^"]*"' | head -1 | sed 's/.*://; s/"//g')"
  awk -v d="$down" -v u="${up:-0}" -v l="${lat:-0}" -v c="$city" -v k="$colo" \
    'BEGIN{ s=c; if(s=="")s=k; if(s=="")s="Cloudflare";
            printf "%.2f %.2f %.2f %s", d*8/1e6, u*8/1e6, l*1000, s }'
}

run_speedtest() {
  local tool="" smode="" dl="" ul="" ping="" srv="" out="" line="" serr="" SPEED_ERR=""

  # 1) Cloudflare (curl) - primary: reliable, no install, returns location
  echo "Method: Cloudflare (curl)"
  line="$(cf_speedtest)"
  [[ -n "$line" ]] && read -r dl ul ping srv <<< "$line"

  # 2) Fallback to Ookla / speedtest-cli only if Cloudflare failed
  if [[ -z "$dl" || "$dl" == "ERR" ]]; then
    if command -v speedtest >/dev/null 2>&1 && speedtest --version 2>&1 | grep -qi 'ookla'; then
      tool="speedtest"; smode="ookla"
    elif command -v speedtest-cli >/dev/null 2>&1; then
      tool="speedtest-cli"; smode="python"
    elif command -v speedtest >/dev/null 2>&1; then
      tool="speedtest"; smode="python"
    fi
    [[ -n "$tool" ]] && echo "Fallback method: $tool ($smode)"
  fi

  if [[ -z "$dl" && "$smode" == "ookla" ]]; then
    out="$("$tool" -f json --accept-license --accept-gdpr 2>/dev/null)"
    if [[ -n "$out" ]] && command -v python3 >/dev/null 2>&1; then
      read -r dl ul ping srv < <(python3 - "$out" 2>/dev/null <<'PY'
import sys, json
try:
    d=json.loads(sys.argv[1])
    print("%.2f %.2f %.2f %s" % (d["download"]["bandwidth"]*8/1e6,
        d["upload"]["bandwidth"]*8/1e6, d["ping"]["latency"],
        d.get("server",{}).get("location") or d.get("server",{}).get("name") or "unknown"))
except Exception:
    print("ERR ERR ERR ERR")
PY
)
    fi
  elif [[ -z "$dl" && "$smode" == "python" ]]; then
    out="$("$tool" --secure --json 2>/dev/null)"
    if [[ -n "$out" ]] && command -v python3 >/dev/null 2>&1; then
      read -r dl ul ping srv < <(python3 - "$out" 2>/dev/null <<'PY'
import sys, json
try:
    d=json.loads(sys.argv[1]); s=d.get("server",{})
    print("%.2f %.2f %.2f %s" % (d["download"]/1e6, d["upload"]/1e6, d["ping"],
        s.get("name") or s.get("sponsor") or "unknown"))
except Exception:
    print("ERR ERR ERR ERR")
PY
)
    fi
    if [[ -z "$dl" || "$dl" == "ERR" ]]; then
      serr="$("$tool" --secure --simple 2>&1)"
      dl="$(echo "$serr"   | sed -nE 's/^Download:[[:space:]]+([0-9.]+).*/\1/p')"
      ul="$(echo "$serr"   | sed -nE 's/^Upload:[[:space:]]+([0-9.]+).*/\1/p')"
      ping="$(echo "$serr" | sed -nE 's/^Ping:[[:space:]]+([0-9.]+).*/\1/p')"
      if [[ -n "$dl" ]]; then srv="unknown"
      else SPEED_ERR="$(echo "$serr" | grep -iE 'error|cannot|unable|HTTP|Exception|Forbidden' | head -1)"; fi
    fi
  fi

  if [[ -z "$dl" || "$dl" == "ERR" ]]; then
    echo "Speed test could not run.${SPEED_ERR:+ Error: $SPEED_ERR}"
    STATUS_SPEED="WARN"; SUM_SPEED="${SPEED_ERR:-speedtest unavailable}"; return
  fi

  echo "Server   : ${srv:-unknown}"
  echo "Download : $(fmt_speed "$dl")"
  echo "Upload   : $(fmt_speed "$ul")"
  echo "Latency  : ${ping} ms"
  STATUS_SPEED="PASS"
  if [[ -n "$srv" && "$srv" != "unknown" ]]; then
    printf -v SUM_SPEED 'Server: %s\nDownload: %s\nUpload: %s\nLatency: %s ms' \
      "$srv" "$(fmt_speed "$dl")" "$(fmt_speed "$ul")" "$ping"
  else
    printf -v SUM_SPEED 'Download: %s\nUpload: %s\nLatency: %s ms' \
      "$(fmt_speed "$dl")" "$(fmt_speed "$ul")" "$ping"
  fi
}

print_perf() {
  section "PERFORMANCE - DISK (fio, 30sn)"
  if command -v fio >/dev/null 2>&1; then
    fio --name=quickwrite --filename=/tmp/.fio_test --size=1G --bs=1M \
        --rw=write --direct=1 --runtime=30 --time_based --group_reporting 2>/dev/null \
        | grep -E 'WRITE:|bw=|iops=' || echo "fio ran (summary unavailable)"
    rm -f /tmp/.fio_test
  else
    echo "fio not installed (apt/yum install fio). Skipping."
  fi

  section "PERFORMANCE - INTERNET SPEED (speedtest)"
  run_speedtest

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
  local label="$1" status="$2" detail="$3" line
  printf "%-12s : %s %s\n" "$label" "$(emoji "$status")" "$status"
  if [[ -n "$detail" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && printf "%-12s    %s\n" "" "$line"
    done <<< "$detail"
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
    "speed_test": { "status": "${STATUS_SPEED:-SKIP}", "details": $(json_details "$SUM_SPEED") },
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
  sum_line "Network"  "$STATUS_NET"     "$SUM_NET"
  echo
  if [[ -n "$STATUS_SPEED" ]]; then
    sum_line "Speed Test" "$STATUS_SPEED" "$SUM_SPEED"
    echo
  fi
  sum_line "IPv6"     "$STATUS_IPV6"    "$SUM_IPV6"
  echo
  sum_line "SMART"    "$STATUS_SMART"   "$SUM_SMART"
  echo
  sum_line "RAID"     "$STATUS_RAID"    "$SUM_RAID"
  echo
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
  print_json > "$JSONFILE"

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
