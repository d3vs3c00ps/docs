---
title: Prometheus backup and restore
description: Back up the Prometheus TSDB with a snapshot from the admin API, restore it, keep the configuration in git, and backfill old data with promtool
tags: [observability, monitoring, prometheus, backup]
type: howto
status: complete
---

# Prometheus backup and restore

A Prometheus server has two things to back up:

- the **configuration**: `prometheus.yml`, the rule files, the file_sd target files.
  These are small text files. Keep them in git.
- the **data**: the TSDB folder (`/prometheus` in the container,
  `/var/lib/prometheus` on a host). It can be large.

Many teams do not back up the TSDB at all: metrics lose value with age, and a new
server starts collecting at once. Back it up when you need the history (capacity
planning, SLA reports), or send it to long-term storage (see the end of this note).

This note uses the lab of [[observability/prometheus/quickstart]]. For a general view of
backups, see backup.

## Turn on the admin API

The snapshot endpoint is part of the admin API, which is off by default. Without it,
the call fails:

```bash
curl -s -X POST http://localhost:9090/api/v1/admin/tsdb/snapshot
```

```json
{"status":"error","errorType":"unavailable","error":"admin APIs disabled"}
```

Add `--web.enable-admin-api` to the command of the `prometheus` service in
`compose.yaml` (or to `ExecStart` in the systemd unit), then `docker compose up -d`:

```yaml
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --web.enable-lifecycle
      - --web.enable-admin-api
```

> [!warning] The admin API can delete data
> The same API has `delete_series` and `clean_tombstones`. Anybody who reaches port
> 9090 can call them. Protect the port with a firewall, or with basic auth
> ([[observability/prometheus/advanced#TLS and basic auth]]).

## Take a snapshot

```bash
SNAP=$(curl -s -X POST http://localhost:9090/api/v1/admin/tsdb/snapshot | jq -r .data.name)
echo "$SNAP"
```

The answer is `{"status":"success","data":{"name":"20261105T131500Z-5f1c..."}}`.
Prometheus writes the snapshot to `<data dir>/snapshots/<name>`:
`/prometheus/snapshots/$SNAP` in the container, `/var/lib/prometheus/snapshots/$SNAP`
on a host.

- A snapshot is fast and small at first: it uses **hard links** to the existing blocks.
  It also writes the recent data (the in-memory *head*) as a new block. Add
  `?skip_head=true` to leave the head out.
- The snapshot is consistent: you can copy it while Prometheus runs.

Copy it out of the container, then delete it from the data folder:

```bash
mkdir -p backup
docker compose cp "prometheus:/prometheus/snapshots/$SNAP" "backup/$SNAP"
docker compose exec prometheus rm -rf "/prometheus/snapshots/$SNAP"
tar -czf "prometheus-$SNAP.tar.gz" -C backup "$SNAP"
```

Delete old snapshots. Because of the hard links, a snapshot keeps old blocks on disk
after retention removed them from the TSDB. The disk then fills up slowly.

## Restore a snapshot

A snapshot folder is a normal TSDB data folder. To restore, stop Prometheus, replace
the content of the data folder, and start it again:

```bash
docker compose stop prometheus
docker compose run --rm --no-deps --user root -v "$PWD/backup:/backup:ro" \
  --entrypoint sh prometheus -c \
  "rm -rf /prometheus/* && cp -r /backup/$SNAP/. /prometheus/ && chown -R nobody:nobody /prometheus"
docker compose start prometheus
```

- `docker compose run` starts a one-off container of the service, with its volume.
- The Prometheus image runs as `nobody`. The files must belong to it, or Prometheus
  cannot write and does not start.
- On a host: `systemctl stop prometheus`, replace `/var/lib/prometheus` with the
  snapshot, `chown -R prometheus:prometheus /var/lib/prometheus`, then start.

Check that the old data is back. Query a time from before the backup (`time=` takes a
Unix timestamp):

```bash
curl -s http://localhost:9090/api/v1/query --data-urlencode 'query=up{job="node"}' \
  --data-urlencode "time=$(date -d '-10 minutes' +%s)" | jq -r '.data.result[].value[1]'
```

It prints `1`. List the blocks with `promtool`:

```bash
docker compose exec prometheus promtool tsdb list /prometheus
```

## What not to do

- **Do not copy a live data folder** with `cp`, `tar` or `rsync`. Prometheus writes the
  WAL and compacts blocks all the time. The copy can mix old and new files, and the
  restored server can lose data or refuse to start. Use a snapshot, or stop Prometheus
  first.
- Do not put the data folder on NFS. Prometheus needs a POSIX local file system.
- Do not keep snapshots in the data folder. Move them to another disk or host.

## Back up the configuration

The configuration is text. Keep it in git, review the changes, and check them in CI
with `promtool check config` and `promtool test rules` (see
[[observability/prometheus/advanced#Unit tests for rules]]):

```bash
git init prometheus-config
cp prometheus.yml prometheus-config/
git -C prometheus-config add prometheus.yml
git -C prometheus-config commit -m "Add the Prometheus configuration"
```

With git, the configuration of a lost server comes back in seconds. The data comes back
from the last snapshot, or not at all.

## Backfill old data

`promtool tsdb create-blocks-from openmetrics` turns a file in the OpenMetrics text
format into TSDB blocks. Use it to import data from another system.

`backfill.om` (timestamps are in seconds; the file must end with `# EOF`):

```text
# HELP backup_test_value A value written by hand.
# TYPE backup_test_value gauge
backup_test_value{source="backfill"} 42 1793865600
backup_test_value{source="backfill"} 43 1793869200
# EOF
```

Create the blocks in a folder next to the data, then move them in and restart:

```bash
docker compose cp backfill.om prometheus:/tmp/backfill.om
docker compose exec prometheus sh -c \
  'promtool tsdb create-blocks-from openmetrics /tmp/backfill.om /prometheus/backfill && mv /prometheus/backfill/* /prometheus/ && rmdir /prometheus/backfill'
docker compose restart prometheus
```

- Do not backfill the last 3 hours: Prometheus is still writing that time range in
  its head block.
- Data older than the retention is deleted at the next cleanup.
- `promtool tsdb create-blocks-from rules` computes a new recording rule for the past,
  from the data already in Prometheus.

## Long-term storage

A single Prometheus keeps data on one disk, for its retention period. For months or
years of data, or for several Prometheus servers in one view, use a long-term storage
system. **Thanos** adds a sidecar next to each Prometheus that uploads the 2-hour blocks
to object storage (S3 and others), and a query layer on top. **Grafana Mimir** (and
Cortex, its parent) receives the data by `remote_write` (see
[[observability/prometheus/advanced#Remote write]]) and stores it in object storage.
With either one, the object storage is the backup, and a lost Prometheus loses only its
last two hours.

## See also

- [[observability/grafana/backup]]: back up the dashboards too.
- [[observability/prometheus/troubleshooting]]

<!-- uplink -->
Part of [[observability/prometheus/index|Prometheus]].
