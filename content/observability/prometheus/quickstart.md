---
title: Prometheus quickstart
description: Run Prometheus and node_exporter with Docker Compose, write a first prometheus.yml, run first PromQL queries, then install Prometheus from the release tarball as a systemd service
tags: [observability, monitoring, prometheus, docker, systemd]
type: howto
status: complete
---

# Prometheus quickstart

Prometheus is a monitoring system and a time series database (TSDB).

- It uses a **pull model**: Prometheus calls an HTTP endpoint (usually `/metrics`) on
  each target, at a fixed interval. This is a *scrape*.
- It stores the samples in its own **TSDB** on local disk.
- You read the data with **PromQL**, its query language, in the web UI, through the
  HTTP API, or from [[observability/grafana/quickstart|Grafana]].

An *exporter* is a small program that exposes metrics for something that has none.
`node_exporter` exposes the metrics of a Linux host: CPU, memory, disks, network.

This note runs Prometheus on a server, not in Kubernetes. For Kubernetes, see
[[kubernetes/observability/prometheus]], [[kubernetes/observability/prometheus-stack]]
and [[kubernetes/observability/metrology/quickstart]].

Versions used here: Prometheus 3.15.1, node_exporter 1.12.1.

## Run it with Docker Compose

Create a project folder with two files. First `compose.yaml`:

```yaml
services:
  prometheus:
    image: prom/prometheus:v3.15.1
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --web.enable-lifecycle
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    restart: unless-stopped

  node-exporter:
    image: prom/node-exporter:v1.12.1
    command:
      - --path.rootfs=/host
    pid: host
    volumes:
      - /:/host:ro
    ports:
      - "9100:9100"
    restart: unless-stopped

volumes:
  prometheus-data:
```

- `--web.enable-lifecycle` turns on the `/-/reload` endpoint. You can then reload the
  configuration without a restart (see [[observability/prometheus/advanced#Reload the configuration]]).
- The named volume `prometheus-data` keeps the TSDB when the container is recreated.
- node_exporter reads the host file systems through `/host`. `pid: host` lets it see
  the host processes.

> [!note] node_exporter in a container
> In a container, node_exporter sees the network of the container, not of the host.
> On a real server, run node_exporter on the host itself (a systemd service, like
> Prometheus [[#Install from the release tarball (systemd)|below]]), or add
> `network_mode: host` and scrape the host address.
>
> The node_exporter README mounts `/:/host:ro,rslave`, so that file systems mounted
> later also show up. Docker Desktop refuses `rslave` (`path / is mounted on / but it
> is not a shared or slave mount`), so this lab uses plain `ro`.

Then `prometheus.yml`, the Prometheus configuration:

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: node
    static_configs:
      - targets: ["node-exporter:9100"]
```

- `global` sets the defaults: scrape every 15 seconds, evaluate rules every 15 seconds.
  The default `scrape_interval` is 1 minute.
- Each entry in `scrape_configs` is a *job*. Prometheus adds the `job` label to every
  series it scrapes for that job.
- `static_configs` lists the targets as `host:port`. Here `node-exporter` is the
  Compose service name. Prometheus reaches it through the Compose network.

### Check the configuration

`promtool` comes with Prometheus. It checks the file before you start:

```bash
docker run --rm -v "$PWD/prometheus.yml:/prometheus.yml:ro" \
  --entrypoint promtool prom/prometheus:v3.15.1 check config /prometheus.yml
```

It prints `SUCCESS: /prometheus.yml is valid prometheus config file syntax`. A broken
file makes it print the error and exit with code 1.

### Start the stack

```bash
docker compose up -d
curl -s http://localhost:9090/-/ready
```

`/-/ready` answers `Prometheus Server is Ready.` once the TSDB is loaded.

## The web UI and the targets API

Open `http://localhost:9090`. The UI has a query page, and a **Status** menu with
**Target health**, **Configuration**, **Rules** and **TSDB status**.

The same information is in the HTTP API. List the targets and their health:

```bash
curl -s http://localhost:9090/api/v1/targets \
  | jq -r '.data.activeTargets[] | [.labels.job, .scrapeUrl, .health, .lastError] | @tsv'
```

```text
node	http://node-exporter:9100/metrics	up
prometheus	http://localhost:9090/metrics	up
```

`health` is `up`, `down` or `unknown` (not scraped yet). When a target is `down`,
`lastError` says why. See [[observability/prometheus/troubleshooting#A target is down]].

## First PromQL queries

Type the queries in the UI, or send them to the API:

```bash
curl -s http://localhost:9090/api/v1/query --data-urlencode 'query=up' \
  | jq -r '.data.result[] | "\(.metric.job) \(.value[1])"'
```

`up` is 1 when the last scrape of a target worked, and 0 when it failed. Prometheus
creates it for every target.

Some useful queries on node_exporter metrics:

```promql
# CPU use in percent, per instance, over the last 5 minutes
100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))

# CPU seconds per second, per mode
sum by (mode) (rate(node_cpu_seconds_total[5m]))

# Memory used, in percent
100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)

# Free space per file system, in percent (pseudo file systems left out)
100 * node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay"}
```

- `node_cpu_seconds_total` is a *counter*: it only goes up. Do not graph a counter
  directly. `rate(...[5m])` gives the per-second increase over the last 5 minutes.
- `rate()` needs at least two samples in the range. With a 15 s scrape interval, wait
  about 30 seconds after the start before the first result.
- `node_memory_*` and `node_filesystem_*` are *gauges*: their value goes up and down,
  so you use them as they are.

## Install from the release tarball (systemd)

Without Docker, install the binary from the GitHub release, and run it as a systemd
service. These steps work on any Linux distribution with systemd.

### Download and check the checksum

```bash
PROM_VERSION=3.15.1
ARCH=$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')
cd /tmp
curl -fsSLO "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-${ARCH}.tar.gz"
curl -fsSLO "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/sha256sums.txt"
sha256sum --check --ignore-missing sha256sums.txt
```

The last command must print `prometheus-3.15.1.linux-amd64.tar.gz: OK` (or `arm64`).
If it prints `FAILED`, do not use the file: download it again.

### Create the user and the folders

Run as root:

```bash
useradd --system --no-create-home --shell /usr/sbin/nologin prometheus
tar -xzf "prometheus-${PROM_VERSION}.linux-${ARCH}.tar.gz"
install -m 0755 "prometheus-${PROM_VERSION}.linux-${ARCH}/prometheus" \
  "prometheus-${PROM_VERSION}.linux-${ARCH}/promtool" /usr/local/bin/
install -d -m 0755 /etc/prometheus
install -d -m 0750 -o prometheus -g prometheus /var/lib/prometheus
```

Prometheus runs as the `prometheus` system user. It can write only to its data
folder, `/var/lib/prometheus`.

### The configuration

`/etc/prometheus/prometheus.yml`:

```yaml
global:
  scrape_interval: 15s

storage:
  tsdb:
    retention:
      time: 30d
      size: 20GB

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]
```

`storage.tsdb.retention` keeps 30 days of data, or 20 GB, whichever limit comes first.
Without it, Prometheus keeps 15 days.

> [!warning] The retention flags are deprecated
> Older guides put `--storage.tsdb.retention.time=30d` in the unit file. That flag
> still works in 3.15, but `prometheus --help` marks it `[DEPRECATED]` (no warning in
> the logs). Use the `retention` block of the configuration file. A reload applies it,
> and it wins when both are set.

### The unit file

`/etc/systemd/system/prometheus.service`:

```ini
[Unit]
Description=Prometheus monitoring system
Documentation=https://prometheus.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --web.listen-address=:9090 \
  --web.enable-lifecycle
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/prometheus

[Install]
WantedBy=multi-user.target
```

- `ExecReload` sends `SIGHUP`, so `systemctl reload prometheus` re-reads the
  configuration without a restart.
- `ProtectSystem=strict` makes the whole file system read-only for the service, except
  the paths in `ReadWritePaths`.

Check, start, and test:

```bash
promtool check config /etc/prometheus/prometheus.yml
systemctl daemon-reload
systemctl enable --now prometheus
curl -s http://localhost:9090/-/ready
```

After a change to `prometheus.yml`:

```bash
promtool check config /etc/prometheus/prometheus.yml && systemctl reload prometheus
```

node_exporter installs the same way, from its own release
(`node_exporter-1.12.1.linux-amd64.tar.gz`, port 9100).

## Next steps

- [[observability/prometheus/advanced]]: relabelling, service discovery, rules,
  Alertmanager, security.
- [[observability/prometheus/backup]]: snapshots and restore.
- [[observability/prometheus/troubleshooting]]: when a target is down or a reload fails.
- [[observability/grafana/quickstart]]: dashboards on top of Prometheus.
- zabbix: another monitoring system, with agents and a push model.

<!-- uplink -->
Part of [[observability/prometheus/index|Prometheus]].
