---
title: Prometheus troubleshooting
description: Find why a target is down, why a reload failed, where high cardinality comes from, and what to do with WAL replay, out-of-order samples, a full disk, clock skew and alerts that never reach Alertmanager
tags: [observability, monitoring, prometheus, alertmanager, troubleshooting]
type: reference
status: complete
---

# Prometheus troubleshooting

Problems and fixes for a Prometheus server and its Alertmanager. The examples use the
lab of [[observability/prometheus/advanced]] (Prometheus 3.15.1, Alertmanager 0.34.2).

Most answers are in three places:

- **Status > Target health** in the UI, or `/api/v1/targets`;
- the logs: `docker compose logs prometheus` or `journalctl -u prometheus`;
- the metrics Prometheus exposes about itself (`prometheus_*`), which it scrapes in
  the `prometheus` job.

## A target is down

List the targets that are not `up`, with the error of their last scrape:

```bash
curl -s http://localhost:9090/api/v1/targets \
  | jq -r '.data.activeTargets[] | select(.health != "up") | [.labels.job, .scrapeUrl, .lastError] | @tsv'
```

`lastError` tells you the cause. The common ones:

| `lastError` contains | Cause | Fix |
| --- | --- | --- |
| `connect: connection refused` | the host answers, nothing listens on this port | check the port, and that the exporter runs and listens on this address, not only on `127.0.0.1` |
| `no such host`, or `server misbehaving` | DNS cannot resolve the name. Which message you get depends on the resolver: `server misbehaving` when it answers with an error instead of "no such name" | fix the name; in Compose, use the service name; check `/etc/resolv.conf` |
| `i/o timeout` | no answer at all: firewall, wrong IP | open the port in the firewall between Prometheus and the target |
| `server gave HTTP response to HTTPS client` | `scheme: https` on a plain HTTP target | remove `scheme: https`, or turn on TLS on the target |
| `x509: certificate signed by unknown authority` | TLS with a CA that Prometheus does not know | set `tls_config.ca_file` |
| `server returned HTTP status 401 Unauthorized` | the target needs a password or a token | set `basic_auth` or `authorization` |
| `server returned HTTP status 404 Not Found` | wrong `metrics_path` | set the path the exporter uses (default `/metrics`) |
| `context deadline exceeded` | the target answered too slowly | raise `scrape_timeout` (at most `scrape_interval`), or make the exporter faster |
| `sample limit exceeded` | the target sent more series than `sample_limit` | see [[#High cardinality]] |
| `unsupported Content-Type` or `blank Content-Type` | the target sends a wrong `Content-Type` header, or none. Prometheus 3 is strict about it | fix the exporter, or set `fallback_scrape_protocol: PrometheusText0.0.4` on the job |

These jobs reproduce four of them. Add them to `scrape_configs` to see the errors:

```yaml
  - job_name: wrong-port
    static_configs:
      - targets: ["node-exporter:9999"]

  - job_name: wrong-name
    static_configs:
      - targets: ["node-exporterr:9100"]

  - job_name: wrong-scheme
    scheme: https
    static_configs:
      - targets: ["node-exporter:9100"]

  - job_name: too-slow
    scrape_timeout: 1ms
    static_configs:
      - targets: ["node-exporter:9100"]
```

Test the connection from the Prometheus host or container, not from your laptop. DNS,
routes and firewalls are often different:

```bash
docker compose exec prometheus wget -qO- http://node-exporter:9100/metrics | head -3
```

If a target is not in the list at all, service discovery did not find it, or
`relabel_configs` dropped it. Look at **Status > Service discovery**, or run
`promtool check service-discovery` (see [[observability/prometheus/advanced#http_sd]]).

## Configuration errors and failed reloads

Always check the file first. `promtool` prints the line and the error:

```bash
docker compose exec prometheus promtool check config /etc/prometheus/prometheus.yml
```

A failed reload does **not** stop Prometheus: it keeps the old configuration, and you
may not notice. Check after each reload:

```promql
prometheus_config_last_reload_successful == 0
```

The log has the reason:

```bash
docker compose logs prometheus | grep 'Error reloading config'
```

At start, a bad file stops Prometheus: the container exits, or systemd restarts it in
a loop. `docker compose ps -a` shows `Exited (2)`, and the last log line has the error.

Typical causes: YAML indentation, tabs instead of spaces, a duplicate `job_name`, a
rule file with a PromQL error, a file that the `nobody` user (the container user)
cannot read.

## High cardinality

Each unique set of labels is a series. Too many series use memory, slow queries, and
can stop Prometheus (out of memory). Labels with unbounded values are the usual cause:
user IDs, full URLs, request IDs, timestamps, IP addresses of clients.

Find the metrics with the most series:

```bash
curl -s http://localhost:9090/api/v1/status/tsdb \
  | jq -r '.data.seriesCountByMetricName[:5][] | "\(.value) \(.name)"'
```

The same in PromQL. This query is expensive; do not put it in a dashboard:

```promql
topk(10, count by (__name__) ({__name__=~".+"}))
```

Then find the label that explodes:

```promql
count(count by (path) (http_requests_total))
```

**Status > TSDB status** shows the same tables. `promtool tsdb analyze <data dir>`
does a deeper analysis, offline.

Fixes:

- fix the exporter or the application: put the route template (`/users/:id`) in the
  label, not the path;
- drop the series or the label with `metric_relabel_configs` (`action: drop`, or
  `labeldrop`);
- protect Prometheus with `sample_limit` on the job. A scrape with more samples fails,
  the target goes `down` with `sample limit exceeded`, and nothing from it is stored:

```yaml
  - job_name: node
    sample_limit: 10
    static_configs:
      - targets: ["node-exporter:9100"]
```

Watch the total with `prometheus_tsdb_head_series`.

## Slow start and WAL replay

At start, Prometheus replays its write-ahead log (WAL) to rebuild the last hours of
data in memory. With many series this takes minutes. Meanwhile:

- `/-/healthy` answers 200, but `/-/ready` answers 503 `Service Unavailable`;
- the UI and the API do not work yet;
- the log says `Replaying WAL, this may take a while`, then `WAL replay completed`.

Wait. Do not restart it in a loop: every restart replays again. With systemd, the
default `Type=simple` does not time out on a slow start. In Kubernetes, give the
readiness probe enough time.

If the WAL is corrupted (power loss, full disk), Prometheus repairs it at start: it
drops the records after the damage, and logs it. You lose those records. If it still
does not start, move the WAL segment named in the error out of `wal/` (keep a copy).
Never delete the whole data folder first: the blocks are safe.

## Out-of-order samples

A sample older than the last one of its series is *out of order*. By default,
Prometheus drops it and counts it:

```promql
rate(prometheus_target_scrapes_sample_out_of_order_total[5m]) > 0
```

Causes: two Prometheus servers that write the same series to the same remote storage
without different `external_labels`; an exporter that sets its own timestamps.

Fix the cause first. To accept late samples on purpose (for example from remote write
or backfilling), set a window. It applies on reload:

```yaml
storage:
  tsdb:
    out_of_order_time_window: 30m
```

## Disk full

Symptoms: `no space left on device` in the logs, scrapes and compactions fail
(`prometheus_tsdb_compactions_failed_total` goes up), and the WAL is corrupted.

- Free some space, or grow the volume, then restart.
- Set `storage.tsdb.retention.size` to 80 to 85% of the disk (see
  [[observability/prometheus/advanced#Retention]]).
- Alert before it happens, on the Prometheus host itself:

```promql
predict_linear(node_filesystem_avail_bytes{mountpoint="/"}[6h], 24 * 3600) < 0
```

## Time skew

Prometheus stores each sample with the time of the **Prometheus server**. If the server
clock is wrong, "now" in a query points to the wrong time, and rules and alerts see
no data or old data. The **Query** page of the UI shows a warning ("Detected a time
difference...") when the clock of your browser and the clock of the server differ by
more than 30 seconds.

Check the clock of each node from the node_exporter metrics (an offset in seconds):

```promql
abs(timestamp(node_time_seconds) - node_time_seconds) > 1
```

Keep every host in sync with NTP: see [[servers/chrony]].

## Query from the command line

`promtool query` runs a query from a terminal or a script, without curl and jq:

```bash
docker compose exec prometheus promtool query instant http://localhost:9090 'up == 0'
docker compose exec prometheus promtool query instant http://localhost:9090 'count by (job) (up)'
```

It prints one line per series, like `{job="node"} => 1 @[1793865600]`.

## Alerts do not reach Alertmanager

Look at each step, from Prometheus to the notification.

**1. Does the alert fire in Prometheus?** **Alerts** page, or:

```bash
curl -s http://localhost:9090/api/v1/alerts | jq -r '.data.alerts[] | [.labels.alertname, .state] | @tsv'
```

A `pending` alert waits for its `for` time.

**2. Does Prometheus know an Alertmanager, and can it send?**

```promql
prometheus_notifications_alertmanagers_discovered
rate(prometheus_notifications_errors_total[5m])
rate(prometheus_notifications_dropped_total[5m])
```

`discovered` must be at least 1. Errors mean that Prometheus cannot reach the address
in `alerting.alertmanagers`.

**3. Does Alertmanager have the alert?**

```bash
curl -s http://localhost:9093/api/v2/alerts | jq -r '.[] | [.labels.alertname, .status.state] | @tsv'
```

`suppressed` means silenced or inhibited. Check the silences with
`amtool silence query`, and the route with `amtool config routes test` (see
[[observability/prometheus/advanced#Alertmanager]]).

**4. Does the notification fail?**

```promql
rate(alertmanager_notification_requests_failed_total[5m]) > 0
```

Each failed attempt is counted there. The label `integration` names the failing type
(`webhook`, `email`, `slack`...). Alertmanager retries; when it gives up, it also counts
`alertmanager_notifications_failed_total` (with a `reason` label) and logs
`Notify for alerts failed`. The log has the error of each attempt, for example a DNS
name that does not resolve:

```bash
docker compose logs alertmanager | grep 'Notify attempt failed'
```

Remember `group_wait`: Alertmanager waits 30 seconds (in the lab) before the first
notification of a group.

## See also

- [[observability/prometheus/quickstart]]
- [[observability/grafana/troubleshooting]]
- [[kubernetes/observability/prometheus]]

<!-- uplink -->
Part of [[observability/prometheus/index|Prometheus]].
