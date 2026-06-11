# Healthcheck Scripts

Automated Linux server health check and validation scripts.

This repository contains scripts designed to verify system health after operating system installation or server provisioning.

## Features

* Operating System verification
* CPU information and health checks
* Memory usage checks
* Storage capacity and usage checks
* Network connectivity checks
* Service status verification
* Health score calculation
* Clean summary output

## How to Run

### Direct Execution

```bash
curl -fsSL https://raw.githubusercontent.com/oguzhaze/healthcheck-scripts/main/healthcheck.sh | bash
```

### Download and Run

```bash
curl -fsSL https://raw.githubusercontent.com/oguzhaze/healthcheck-scripts/main/healthcheck.sh -o /usr/local/bin/healthcheck.sh

chmod +x /usr/local/bin/healthcheck.sh

/usr/local/bin/healthcheck.sh
```

## First Boot Integration

```bash
curl -fsSL https://raw.githubusercontent.com/oguzhaze/healthcheck-scripts/main/healthcheck.sh -o /usr/local/bin/healthcheck.sh

chmod +x /usr/local/bin/healthcheck.sh

/usr/local/bin/healthcheck.sh
```

## Example Output

```text
=========================
   HEALTHCHECK SUMMARY
=========================

Health Score : 100/100
Overall      : HEALTHY

Hostname     : bash-test.servernet.net
OS           : Ubuntu 24.04.4 LTS
CPU          : AMD Ryzen 9 7900
RAM          : 62 GB
Storage      : 877 GB
IPv4         : 85.208.198.210

-------------------------
 Details
-------------------------

OS           : ✅ PASS
                Ubuntu 24.04.4 LTS
                Kernel 6.8.0-124-generic

Time         : ✅ PASS
                Timezone: Europe/London
                NTP synchronized: yes

CPU          : ✅ PASS
                AMD Ryzen 9 7900 12-Core Processor
                12 Cores / 24 Threads

Memory       : ✅ PASS
                62 GB RAM
                8 GB Swap

Storage      : ✅ PASS
                Filesystem: ext4
                Root Disk: 877 GB
                Used: 11 GB (2%)
                Free: 829 GB

Network      : ✅ PASS
                IPv4: 85.208.198.210/29
                Gateway: 85.208.198.209 ✅ Reachable
                DNS: 85.208.196.51,85.208.196.52 ✅ Working
                Internet: ✅ Connected

Speed Test   : ✅ PASS
                Server: London
                Download: 950.29 Mbps
                Upload: 844.25 Mbps
                Latency: 2.49 ms

IPv6         : ⏭️ N/A
                IPv6 not configured

SMART        : ✅ PASS
                2/2 disk(s) PASSED
                Temperature: 40°C
                SSD Wear: 2%

RAID         : ✅ PASS
                Type: Hardware RAID
                Controller: Broadcom / LSI MegaRAID 12GSAS/PCIe Secure SAS38xx

SSH          : ✅ PASS
                Service active

Firewall     : ℹ️ INFO
                No active firewall detected

dmesg        : ✅ PASS
                No critical storage or hardware errors detected

Warnings:
  - None

Result       : HEALTHY

Log file: /var/log/healthcheck_20260611_131814.log

===== HEALTHCHECK COMPLETED =====
```

## Requirements

* Linux operating system
* Bash shell
* Root privileges recommended

## License

MIT License
