---
title: Prometheus advanced configuration
description: Relabelling, file and HTTP service discovery, recording and alerting rules with unit tests, Alertmanager routing, retention, reload, remote write, TLS and basic auth, native histograms and useful PromQL
tags: [observability, monitoring, prometheus, alertmanager, promql]
type: reference
status: complete
---

# Prometheus advanced configuration

This note goes past [[observability/prometheus/quickstart]]. It uses one lab: Prometheus,
Alertmanager and node_exporter in Docker Compose. Each section adds one feature to it.

Versions: Prometheus 3.15.1, Alertmanager 0.34.2, node_exporter 1.12.1.

## The lab

The project folder looks like this:

```text
.
├── compose.yaml
├── prometheus/
│   ├── prometheus.yml
│   ├── rules/node.yml
│   ├── targets/node.yml
│   └── tests/node_test.yml
└── alertmanager/
    └── alertmanager.yml
```

`compose.yaml`:

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
      - ./prometheus:/etc/prometheus:ro
      - prometheus-data:/prometheus

  alertmanager:
    image: prom/alertmanager:v0.34.2
    command:
      - --config.file=/etc/alertmanager/alertmanager.yml
      - --storage.path=/alertmanager
      - --cluster.listen-address=
    ports:
      - "9093:9093"
    volumes:
      - ./alertmanager:/etc/alertmanager:ro
      - alertmanager-data:/alertmanager

  node-exporter:
    image: prom/node-exporter:v1.12.1
    command:
      - --path.rootfs=/host
    pid: host
    volumes:
      - /:/host:ro

volumes:
  prometheus-data:
  alertmanager-data:
```

- The whole `prometheus/` folder is mounted, not single files. Many editors save a file
  as a new file (a new inode). A single-file bind mount then keeps showing the old
  content, and a reload reads the old file.
- `--cluster.listen-address=` (empty) turns off the Alertmanager cluster mode. You need
  it only with two or more Alertmanagers.

`prometheus/prometheus.yml`:

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    site: lab

storage:
  tsdb:
    retention:
      time: 30d
      size: 10GB

rule_files:
  - /etc/prometheus/rules/*.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager:9093"]

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: alertmanager
    static_configs:
      - targets: ["alertmanager:9093"]

  - job_name: node
    file_sd_configs:
      - files: ["/etc/prometheus/targets/*.yml"]
    relabel_configs:
      # Show "node-exporter", not "node-exporter:9100", in the instance label.
      - source_labels: [__address__]
        regex: "([^:]+):[0-9]+"
        target_label: instance
    metric_relabel_configs:
      # Do not store the Go runtime metrics of node_exporter.
      - source_labels: [__name__]
        regex: "go_.*"
        action: drop
```

`external_labels` are added to every series and alert that leaves this Prometheus
(to Alertmanager, remote storage, federation). Use them to tell servers apart.

Start the lab:

```bash
docker compose up -d
curl -s http://localhost:9090/-/ready
curl -s http://localhost:9093/-/ready
```

## Relabelling

Relabelling rewrites labels with a list of rules. Each rule reads `source_labels`,
joins their values with `;`, matches the result against `regex` (anchored at both
ends), then does its `action`. The default action is `replace`, and the default
`replacement` is `$1`.

There are two places, and they run at different times:

| Key | Runs | Sees | Use it to |
| --- | --- | --- | --- |
| `relabel_configs` | before the scrape, once per target | the target labels, and the `__meta_*` labels from service discovery | pick targets, set `instance`, change `__address__` or `__scheme__` |
| `metric_relabel_configs` | after the scrape, on every sample | the labels of each series | drop series or labels you do not want to store |

Labels that start with `__` are removed after target relabelling. Only `__name__`
stays. So copy what you need from `__meta_*` into a normal label.

The main actions:

| Action | Effect |
| --- | --- |
| `replace` | write `replacement` (with `$1`, `$2`...) to `target_label` |
| `keep` / `drop` | keep or drop the target (or series) when the regex matches |
| `labelmap` | copy every label whose name matches to a new name |
| `labeldrop` / `labelkeep` | remove labels by name |
| `hashmod` | split targets between several Prometheus servers |
| `lowercase` / `uppercase` | change the case of a value |

In the lab, the `node` job sets `instance` without the port, and drops the `go_*`
series of node_exporter:

```promql
up{job="node"}
count({job="node", __name__=~"go_.*"})
```

The first query shows `instance="node-exporter"`. The second one returns nothing.

`metric_relabel_configs` does not reduce the scrape itself: the target still sends
every series. It only saves storage and memory in Prometheus.

## Service discovery

Static lists do not scale. Prometheus has many service discovery (SD) mechanisms:
`file_sd`, `http_sd`, DNS, Consul, cloud providers, Kubernetes. Each one produces
targets with `__meta_*` labels.

### file_sd

`prometheus/targets/node.yml`:

```yaml
- targets: ["node-exporter:9100"]
  labels:
    env: lab
```

Prometheus watches the files. A new or changed file is used **without a reload**. A
configuration management tool (Ansible, Salt) or a script can write these files. Write
to a temporary file and rename it, so Prometheus never reads half a file.

Each target gets the `__meta_filepath` label, and the `labels` of its group.

### http_sd

`http_sd` asks an HTTP endpoint for the targets. The endpoint returns JSON, with the
same structure as a file_sd file, and the `Content-Type: application/json` header:

```json
[
  { "targets": ["node-exporter:9100"], "labels": { "env": "from-http" } }
]
```

The job:

```yaml
  - job_name: node-http-sd
    http_sd_configs:
      - url: http://sd:8000/targets.json
        refresh_interval: 1m
```

Here `sd` is any web server in the same network. In real life, it is your inventory
or CMDB. Prometheus keeps the last good list when the endpoint fails.

To see what a SD job finds, and what relabelling does with it:

```bash
docker compose exec prometheus promtool check service-discovery /etc/prometheus/prometheus.yml node
```

## Recording and alerting rules

A *recording rule* saves the result of a query as a new series. Dashboards then read
a cheap, precomputed series. An *alerting rule* fires an alert when its query returns
something for longer than `for`.

`prometheus/rules/node.yml`:

```yaml
groups:
  - name: node
    rules:
      - record: instance:node_cpu_utilisation:rate5m
        expr: 1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))

      - alert: InstanceDown
        expr: up == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.instance }} of job {{ $labels.job }} is down"

      - alert: HostHighCpu
        expr: instance:node_cpu_utilisation:rate5m > 0.9
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "CPU above 90% on {{ $labels.instance }}"

  - name: meta
    rules:
      - alert: Watchdog
        expr: vector(1)
        labels:
          severity: none
        annotations:
          summary: Always firing. If it stops, the alert pipeline is broken.
```

- The record name follows the convention `level:metric:operations`.
- An alert is `pending` while `for` runs, then `firing`.
- `Watchdog` fires all the time. An external "dead man's switch" service expects it,
  and pages you when it stops.

Check the rules. `promtool check config` also checks the rule files that the
configuration loads:

```bash
docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" --entrypoint promtool \
  prom/prometheus:v3.15.1 check rules /etc/prometheus/rules/node.yml
```

### Unit tests for rules

`promtool test rules` runs rules on fake series, and compares the result with what you
expect. `prometheus/tests/node_test.yml`:

```yaml
rule_files:
  - ../rules/node.yml

evaluation_interval: 1m

tests:
  - interval: 1m
    input_series:
      # up for 2 minutes, then down
      - series: 'up{job="node", instance="web-01"}'
        values: "1 1 0 0 0 0 0"
    alert_rule_test:
      - eval_time: 3m
        alertname: InstanceDown
        exp_alerts: []
      - eval_time: 5m
        alertname: InstanceDown
        exp_alerts:
          - exp_labels:
              severity: critical
              job: node
              instance: web-01
            exp_annotations:
              summary: "web-01 of job node is down"

  - interval: 1m
    input_series:
      # idle all the time: one CPU second per second
      - series: 'node_cpu_seconds_total{instance="web-01", cpu="0", mode="idle"}'
        values: "0+60x10"
    promql_expr_test:
      - expr: instance:node_cpu_utilisation:rate5m
        eval_time: 10m
        exp_samples:
          - labels: 'instance:node_cpu_utilisation:rate5m{instance="web-01"}'
            value: 0
```

- `values: "0+60x10"` means 0, then +60 ten times: 0, 60, 120... 600.
- At 3m, `up` is 0 for one minute only: the alert is `pending`, not in the list.
- At 5m, it is 0 for three minutes, more than `for: 2m`: the alert fires.

```bash
docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" --entrypoint promtool \
  prom/prometheus:v3.15.1 test rules /etc/prometheus/tests/node_test.yml
```

A failed test prints the expected and the actual alerts, and exits with code 1. Run it
in CI next to `promtool check config`.

## Alertmanager

Prometheus only evaluates alerts. Alertmanager receives them, groups them, removes
duplicates, applies silences and inhibitions, and sends notifications.

`alertmanager/alertmanager.yml`:

```yaml
route:
  receiver: team-ops
  group_by: [alertname, instance]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - matchers: ['alertname = "Watchdog"']
      receiver: "null"
    - matchers: ['severity = "critical"']
      receiver: team-ops-pager

receivers:
  - name: "null"
  - name: team-ops
    webhook_configs:
      - url: http://chat-bridge.internal.example.com:8080/alerts
  - name: team-ops-pager
    webhook_configs:
      - url: http://pager.internal.example.com:8080/alerts

inhibit_rules:
  - source_matchers: ['alertname = "InstanceDown"']
    target_matchers: ['severity = "warning"']
    equal: [instance]
```

**The routing tree.** An alert enters at the root `route`. Alertmanager tries the child
`routes` in order. The first one whose `matchers` match takes the alert, unless it
has `continue: true`. With no match, the root receiver gets it.

**Grouping.** `group_by` puts alerts with the same label values into one notification.

| Setting | Meaning |
| --- | --- |
| `group_wait` | wait this long before the first notification of a new group, to collect more alerts |
| `group_interval` | wait this long before notifying about new alerts in a group already sent |
| `repeat_interval` | send again a notification that did not change after this time |

**Inhibition.** While `InstanceDown` fires for an instance, the `warning` alerts of the
same instance are muted. One cause, one page.

A receiver with no configuration (`"null"`) drops the alerts. The real receivers here
are webhooks. Alertmanager also has email, Slack, PagerDuty, Opsgenie, Microsoft
Teams, Telegram and more.

> [!note] Matchers
> `matchers` replaces the old `match` and `match_re` keys. The syntax is the one of
> PromQL: `severity = "critical"`, `instance =~ "web-.*"`, `env != "test"`.

Check the file and the routing with `amtool`:

```bash
docker run --rm -v "$PWD/alertmanager:/etc/alertmanager:ro" --entrypoint amtool \
  prom/alertmanager:v0.34.2 check-config /etc/alertmanager/alertmanager.yml

docker run --rm -v "$PWD/alertmanager:/etc/alertmanager:ro" --entrypoint amtool \
  prom/alertmanager:v0.34.2 config routes test \
  --config.file=/etc/alertmanager/alertmanager.yml severity=critical alertname=InstanceDown
```

The second command prints the receiver that gets this alert: `team-ops-pager`.

### Silences with amtool

A silence mutes alerts that match its matchers, for a fixed time. Use it during
maintenance:

```bash
docker compose exec alertmanager amtool --alertmanager.url=http://localhost:9093 \
  silence add instance=web-01 --duration=2h --author=ops --comment="kernel update"
docker compose exec alertmanager amtool --alertmanager.url=http://localhost:9093 silence query
```

`silence add` prints the ID of the silence. `silence expire ID` ends it early.

To test the routing and the inhibition without Prometheus, send fake alerts:

```bash
docker compose exec alertmanager amtool --alertmanager.url=http://localhost:9093 \
  alert add alertname=InstanceDown instance=web-02 severity=critical
docker compose exec alertmanager amtool --alertmanager.url=http://localhost:9093 \
  alert add alertname=HostHighCpu instance=web-02 severity=warning
curl -s 'http://localhost:9093/api/v2/alerts?inhibited=true' \
  | jq -r '.[] | [.labels.alertname, .status.state] | @tsv'
```

`HostHighCpu` is `suppressed` (inhibited by `InstanceDown`). `InstanceDown` is
`active`.

## Retention

Prometheus deletes old data by time, by size, or both. In Prometheus 3.x, set it in
`prometheus.yml` (see the lab):

```yaml
storage:
  tsdb:
    retention:
      time: 30d
      size: 10GB
```

- The first limit reached wins. Without any setting, Prometheus keeps 15 days.
- Size counts the blocks, the WAL and the head chunks, but only whole blocks are
  deleted. Set `size` to 80 to 85% of the disk, and keep the rest for compaction.
- A reload applies a new retention. Old blocks are deleted within a minute.
- The command-line flags `--storage.tsdb.retention.time` and
  `--storage.tsdb.retention.size` still work, but they are deprecated. The file wins
  over them.

The current values are on **Status > Runtime & build information**, and in the API:

```bash
curl -s http://localhost:9090/api/v1/status/runtimeinfo | jq -r .data.storageRetention
```

## Reload the configuration

Prometheus re-reads `prometheus.yml` and the rule files on a reload. Three ways:

```bash
# HTTP, needs --web.enable-lifecycle
curl -X POST http://localhost:9090/-/reload

# a SIGHUP signal (systemctl reload sends one too, see the quickstart unit)
docker compose kill -s SIGHUP prometheus
```

When the new file is wrong, the reload fails. Prometheus keeps the **old**
configuration and goes on. `/-/reload` answers HTTP 500 with the error. Check the
result after each reload:

```promql
prometheus_config_last_reload_successful
```

It is 1 after a good reload, 0 after a failed one. Add an alert on it. Always run
`promtool check config` before a reload.

Alertmanager reloads the same way: `POST /-/reload` or `SIGHUP`. The metric is
`alertmanager_config_last_reload_successful`.

Prometheus can also reload by itself when the file changes: start it with
`--config.auto-reload` (checks every 30 s by default).

## Remote write

`remote_write` sends a copy of every new sample to another system: Mimir, Thanos
Receive, VictoriaMetrics, or another Prometheus. Local storage keeps working. Add at
the end of `prometheus.yml`:

```yaml
remote_write:
  - url: http://remote:9090/api/v1/write
    write_relabel_configs:
      - source_labels: [__name__]
        regex: "up|instance:.*"
        action: keep
```

- `write_relabel_configs` choose what to send. Here: `up` and the recording rules only.
- The `external_labels` (`site: lab`) are added to the series that are sent.
- A Prometheus accepts remote write only when started with
  `--web.enable-remote-write-receiver`.
- Prometheus keeps the samples in its WAL while the remote is down, and retries.
  Watch `prometheus_remote_storage_samples_failed_total` and
  `prometheus_remote_storage_highest_timestamp_in_seconds`.

## TLS and basic auth

Prometheus and Alertmanager have no authentication by default. Anybody who reaches port
9090 can read every metric, and with `--web.enable-lifecycle`, reload or stop the
server. Put them behind a firewall, and turn on TLS and basic auth with a web
configuration file.

Create a certificate (self-signed here; use your own CA in production) and a bcrypt
hash of the password. `htpasswd` is in the `apache2-utils` (Debian) or `httpd-tools`
(RHEL) package:

```bash
mkdir -p prometheus/tls prometheus/secrets
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout prometheus/tls/prometheus.key -out prometheus/tls/prometheus.crt \
  -subj "/CN=prometheus.example.com" \
  -addext "subjectAltName=DNS:prometheus.example.com,DNS:localhost"
chmod 644 prometheus/tls/prometheus.key
printf '%s' 'change-me' >prometheus/secrets/admin-password
htpasswd -nbBC 10 "" 'change-me' | tr -d ':\n'
```

The key is made readable because the container runs as `nobody`. On a host, make the
key owned by the `prometheus` user, mode 600, instead.

`prometheus/web.yml`, with the hash from `htpasswd`:

```yaml
tls_server_config:
  cert_file: /etc/prometheus/tls/prometheus.crt
  key_file: /etc/prometheus/tls/prometheus.key

basic_auth_users:
  admin: $2y$10$REPLACE.WITH.THE.HASH.FROM.HTPASSWD
```

Check it, and add the flag to the service in `compose.override.yaml` (Compose merges
this file into `compose.yaml` by itself):

```bash
docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" --entrypoint promtool \
  prom/prometheus:v3.15.1 check web-config /etc/prometheus/web.yml
```

```yaml
services:
  prometheus:
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --web.enable-lifecycle
      - --web.config.file=/etc/prometheus/web.yml
```

Prometheus now scrapes **itself** through TLS and basic auth too. Change the
`prometheus` job, or its target goes `down`:

```yaml
  - job_name: prometheus
    scheme: https
    tls_config:
      ca_file: /etc/prometheus/tls/prometheus.crt
    basic_auth:
      username: admin
      password_file: /etc/prometheus/secrets/admin-password
    static_configs:
      - targets: ["localhost:9090"]
```

```bash
docker compose up -d
curl -s --cacert prometheus/tls/prometheus.crt -u admin:change-me https://localhost:9090/-/ready
```

Without the password, Prometheus answers `401 Unauthorized`. Grafana and other clients
need the same credentials. The flag is still marked "experimental", but it has been
there since Prometheus 2.24 and node_exporter and Alertmanager use the same file
format.

## Native histograms and UTF-8 names

**Native histograms** are stable since Prometheus 3.8. A native histogram is one
series with dynamic buckets, instead of one series per `le` bucket. They are more
precise and cheaper to store. Prometheus does not scrape them unless you ask, per job
or in `global`:

```yaml
  - job_name: prometheus
    scrape_native_histograms: true
    static_configs:
      - targets: ["localhost:9090"]
```

When a target exposes both forms, Prometheus then stores only the native one: the
`_bucket` series disappear. Set `always_scrape_classic_histograms: true` to keep both
during a migration. Query a native histogram by its base name, with no `le`:

```promql
histogram_quantile(0.9, sum(rate(prometheus_http_request_duration_seconds[5m])))
```

The `--enable-feature=native-histograms` flag of older versions does nothing since
3.9: use `scrape_native_histograms`.

**UTF-8 names** are allowed since Prometheus 3.0 (for example OpenTelemetry names with
dots). A name with other characters than letters, digits, `_` and `:` goes in quotes,
inside the braces:

```promql
{"http.server.request.duration", "http.route"="/api"}
```

The classic syntax still works for classic names: `{"up", job="node"}` is the same as
`up{job="node"}`.

## Useful PromQL patterns

```promql
# rate: average per-second increase over the range. Use it for alerts and graphs.
rate(node_network_receive_bytes_total[5m])

# irate: uses only the last two samples. Very reactive, very noisy. Zoomed-in graphs only.
irate(node_network_receive_bytes_total[5m])

# 95th percentile of HTTP request duration, from a classic histogram. Keep "le" in "by".
histogram_quantile(0.95, sum by (le, handler) (rate(prometheus_http_request_duration_seconds_bucket[5m])))

# 1 when no series match: alert when a job disappears completely
absent(up{job="node"})

# file systems that will be full in 4 hours, from the trend of the last 6 hours
predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}[6h], 4 * 3600) < 0

# the 5 series that use the most memory
topk(5, node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes)
```

- Use a range of at least 4 times the scrape interval in `rate()`: `[1m]` with a 15 s
  interval.
- Always `rate()` first, then `sum`. Summing counters before `rate()` breaks on counter
  resets.
- `up == 0` cannot see a target that is gone from service discovery. `absent()` can.

## See also

- [[observability/prometheus/backup]]
- [[observability/prometheus/troubleshooting]]
- [[observability/grafana/advanced]]: alerting in Grafana instead of Alertmanager.
- [[kubernetes/observability/prometheus-stack]]: the same parts, run by the Prometheus
  Operator in Kubernetes.

<!-- uplink -->
Part of [[observability/prometheus/index|Prometheus]].
