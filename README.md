# Healthcheck Scripts

Server.net automated health check script for Linux servers.

This repository contains health check and deployment scripts used to verify server status after operating system installation.

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

Hostname     : server.example.com
OS           : Ubuntu 24.04 LTS
CPU          : AMD Ryzen 9 7900
RAM          : 62 GB
Storage      : 877 GB
IPv4         : 85.xxx.xxx.xxx
```

## Requirements

* Linux operating system
* Bash shell
* Root privileges recommended

## License

Internal use for server deployment and health monitoring.
