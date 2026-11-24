---
title: Backup and restore tasks with Task
description: A Taskfile for backups — timestamped tar archives, retention, preconditions on disk space, a dry run, a restore that asks first, a Prometheus TSDB snapshot and a Grafana dashboard export
tags: [dev, tooling, task, build, backup]
type: howto
status: complete
---

# Backup and restore tasks with Task

A backup script grows options: which directory, where to, how many copies to keep,
"what would it do?". A Taskfile gives these for free: variables you can change on the
command line, checks before anything runs, a dry run, a confirmation prompt, and
`task --list` as the help page.

This note builds one `Taskfile.yml` with:

- a tar backup with a timestamped name, and a retention of the N newest archives;
- checks: the source exists, the target is writable, there is enough free space;
- a restore that asks before it replaces anything;
- a Prometheus TSDB snapshot, and a Grafana dashboard export.

It uses Task v3.54.0. For the Task features used here, see [[dev/taskfile/quickstart]]
and [[dev/taskfile/advanced]]. For what to back up in each tool, see
[[observability/prometheus/backup]] and [[observability/grafana/backup]].

## The Taskfile

```yaml
version: "3"

vars:
  SRC: ./data                    # the directory to back up
  NAME: data                     # archive prefix
  BACKUP_DIR: ./backups
  KEEP: 7                        # archives to keep per prefix
  MIN_FREE_MB: 1024
  STAMP:
    sh: date +%Y%m%d-%H%M%S
  PROM_URL: http://localhost:9090
  PROM_DATA: /var/lib/prometheus # Prometheus --storage.tsdb.path, on this host
  GRAFANA_URL: http://localhost:3000

tasks:
  backup:
    desc: Archive SRC into BACKUP_DIR, then keep the KEEP newest archives
    deps: [backup-dir]
    preconditions:
      - sh: test -d "{{.SRC}}"
        msg: "Source directory {{.SRC}} does not exist"
      - sh: test -w "{{.BACKUP_DIR}}"
        msg: "Cannot write to {{.BACKUP_DIR}}"
      - sh: test "$(df -Pm "{{.BACKUP_DIR}}" | awk 'NR==2 {print $4}')" -ge {{.MIN_FREE_MB}}
        msg: "Less than {{.MIN_FREE_MB}} MB free in {{.BACKUP_DIR}}"
    cmds:
      - tar -czf "{{.BACKUP_DIR}}/{{.NAME}}-{{.STAMP}}.tar.gz" -C "{{.SRC}}" .
      - echo "wrote {{.BACKUP_DIR}}/{{.NAME}}-{{.STAMP}}.tar.gz"
      - task: prune
        vars: { PREFIX: "{{.NAME}}" }

  backup:daily:
    desc: Run backup, unless an archive from today already exists
    status:
      - find "{{.BACKUP_DIR}}" -maxdepth 1 -name "{{.NAME}}-$(date +%Y%m%d)-*.tar.gz" | grep -q .
    cmds:
      - task: backup

  backup-dir:
    internal: true
    status:
      - test -d "{{.BACKUP_DIR}}"
    cmds:
      - mkdir -p "{{.BACKUP_DIR}}"

  prune:
    desc: Delete all but the KEEP newest archives with this PREFIX
    requires:
      vars: [PREFIX]
    cmds:
      - >-
        find "{{.BACKUP_DIR}}" -maxdepth 1 -name "{{.PREFIX}}-*.tar.gz"
        | sort -r | tail -n +$(( {{.KEEP}} + 1 )) | xargs -r rm -v --

  restore:
    desc: Replace SRC with the content of ARCHIVE (asks first)
    requires:
      vars: [ARCHIVE]
    preconditions:
      - sh: test -f "{{.ARCHIVE}}"
        msg: "No such archive: {{.ARCHIVE}}"
      - sh: tar -tzf "{{.ARCHIVE}}" >/dev/null
        msg: "{{.ARCHIVE}} is not a readable tar.gz archive"
    prompt: "Replace {{.SRC}} with {{.ARCHIVE}}? The current content moves to {{.SRC}}.old"
    cmds:
      - rm -rf "{{.SRC}}.old"
      - cmd: mv "{{.SRC}}" "{{.SRC}}.old"
        if: test -d "{{.SRC}}"
      - mkdir -p "{{.SRC}}"
      - tar -xzf "{{.ARCHIVE}}" -C "{{.SRC}}"
      - echo "restored {{.ARCHIVE}} into {{.SRC}}"

  restore:latest:
    desc: Restore the newest archive of NAME
    vars:
      LATEST:
        sh: find "{{.BACKUP_DIR}}" -maxdepth 1 -name "{{.NAME}}-*.tar.gz" | sort | tail -n 1
    cmds:
      - task: restore
        vars: { ARCHIVE: "{{.LATEST}}" }

  prometheus:snapshot:
    desc: Take a Prometheus TSDB snapshot and archive it
    deps: [backup-dir]
    set: [pipefail]
    preconditions:
      - sh: curl -fsS -o /dev/null "{{.PROM_URL}}/-/ready"
        msg: "Prometheus is not ready at {{.PROM_URL}}"
      - sh: test -d "{{.PROM_DATA}}"
        msg: "{{.PROM_DATA}} not found: run this task on the Prometheus host"
    cmds:
      - |
        name=$(curl -fsS -X POST "{{.PROM_URL}}/api/v1/admin/tsdb/snapshot" | jq -r .data.name)
        echo "snapshot $name"
        tar -czf "{{.BACKUP_DIR}}/prometheus-{{.STAMP}}.tar.gz" -C "{{.PROM_DATA}}/snapshots" "$name"
        rm -rf "{{.PROM_DATA}}/snapshots/$name"
      - echo "wrote {{.BACKUP_DIR}}/prometheus-{{.STAMP}}.tar.gz"
      - task: prune
        vars: { PREFIX: prometheus }

  grafana:export:
    desc: Export every Grafana dashboard as JSON (needs GRAFANA_TOKEN in the environment)
    deps: [backup-dir]
    set: [pipefail]
    requires:
      vars: [GRAFANA_TOKEN]
    vars:
      OUT: grafana-{{.STAMP}}
    cmds:
      - mkdir -p "{{.BACKUP_DIR}}/{{.OUT}}"
      - defer: rm -rf "{{.BACKUP_DIR}}/{{.OUT}}"
      - |
        curl -fsS -H "Authorization: Bearer $GRAFANA_TOKEN" \
          "{{.GRAFANA_URL}}/api/search?type=dash-db&limit=5000" \
          | jq -r '.[].uid' \
          | while read -r uid; do
              curl -fsS -H "Authorization: Bearer $GRAFANA_TOKEN" \
                "{{.GRAFANA_URL}}/api/dashboards/uid/$uid" \
                | jq '.dashboard' >"{{.BACKUP_DIR}}/{{.OUT}}/$uid.json"
              echo "exported $uid"
            done
      - tar -czf "{{.BACKUP_DIR}}/{{.OUT}}.tar.gz" -C "{{.BACKUP_DIR}}" "{{.OUT}}"
      - echo "wrote {{.BACKUP_DIR}}/{{.OUT}}.tar.gz"
      - task: prune
        vars: { PREFIX: grafana }
```

`task --list` is the help page:

```text
task: Available tasks for this project:
* backup:                    Archive SRC into BACKUP_DIR, then keep the KEEP newest archives
* prune:                     Delete all but the KEEP newest archives with this PREFIX
* restore:                   Replace SRC with the content of ARCHIVE (asks first)
* backup:daily:              Run backup, unless an archive from today already exists
* grafana:export:            Export every Grafana dashboard as JSON (needs GRAFANA_TOKEN in the environment)
* prometheus:snapshot:       Take a Prometheus TSDB snapshot and archive it
* restore:latest:            Restore the newest archive of NAME
```

Task lists names without a `:` first. The top-level `vars:` are defaults. Change any
of them on the command line: `task backup SRC=/srv/app NAME=app KEEP=14`. Do not set
them again inside a task: a task's own `vars:` win over the command line.

The commands were tested on Linux, with GNU `tar`, `find`, `xargs` and `df`.

## Back up a directory

```bash
task backup
```

```text
task: [backup-dir] mkdir -p "./backups"
task: [backup] tar -czf "./backups/data-20261105-093000.tar.gz" -C "./data" .
task: [backup] echo "wrote ./backups/data-20261105-093000.tar.gz"
wrote ./backups/data-20261105-093000.tar.gz
task: [prune] find "./backups" -maxdepth 1 -name "data-*.tar.gz" | sort -r | tail -n +$(( 7 + 1 )) | xargs -r rm -v --
```

- **The name.** `STAMP` is a `sh:` variable. Task runs `date` once per invocation, so
  every task in the same run uses the same timestamp. The format
  `YYYYMMDD-HHMMSS` sorts by name in time order, which is what `prune` relies on.
- **`backup-dir`** has a `status:` check: it runs `mkdir` only when the directory
  is missing. It is `internal`, so it is not in `task --list` and cannot be called
  directly.
- **The checks.** `deps` run first, then the `preconditions`. If one fails, Task prints
  its `msg` and stops with exit code `201`, before `tar` starts:

```text
task: Less than 1024 MB free in ./backups
task: Failed to run task "backup": task: precondition not met
```

- **`-C "{{.SRC}}" .`** stores paths relative to the source, so a restore can go to
  another directory.
- **`backup:daily`** is for cron. Its `status:` check finds an archive with today's
  date, so a second run on the same day does nothing.

## Keep the N newest archives

`prune` lists the archives of one prefix, sorts them newest first, skips the first
`KEEP`, and deletes the rest:

```bash
task prune PREFIX=data KEEP=3
```

`xargs -r` runs nothing when the list is empty. `find` is used instead of `ls data-*`,
because `ls` fails when no file matches, and a failed command stops the task.
`backup`, `prometheus:snapshot` and `grafana:export` call `prune` with their own
prefix, so each kind of backup keeps its own `KEEP` archives.

> [!warning] Retention on one disk is not a backup
> These archives are on the same machine as the data. Copy `BACKUP_DIR` to another
> host or to object storage, for example with `rsync` or `rclone`, in another task.

## Dry run

`--dry` (`-n`) prints the commands, with the variables filled in, and runs none of
them:

```bash
task --dry backup NAME=app
```

```text
task: Task "backup-dir" is up to date
task: [backup] tar -czf "./backups/app-20261105-093000.tar.gz" -C "./data" .
task: [backup] echo "wrote ./backups/app-20261105-093000.tar.gz"
task: [prune] find "./backups" -maxdepth 1 -name "app-*.tar.gz" | sort -r | tail -n +$(( 7 + 1 )) | xargs -r rm -v --
```

No archive is written and nothing is deleted. But a dry run is not a "do nothing"
run:

- `sh:` variables run (`date` here);
- `status:` and `preconditions:` run. `backup-dir` is checked, and
  `task --dry backup SRC=/srv/missing` fails on the first precondition, as a real run
  would.

Keep these checks read-only, and never take a snapshot in a `sh:` variable.

## Restore

```bash
task restore ARCHIVE=./backups/data-20261105-093000.tar.gz
```

```text
Replace ./data with ./backups/data-20261105-093000.tar.gz? The current content moves to ./data.old [y/N]:
```

- `requires:` stops the task with exit code `206` if `ARCHIVE` is missing.
- The two `preconditions` check that the file exists and that tar can read it, before
  the question.
- Any answer but `y` cancels with exit code `205`. Nothing is changed.
- The old content is moved to `./data.old`, not deleted, until the next restore.
- `task restore:latest` restores the newest archive of `NAME`.

With no terminal (cron, CI, `ssh host task ...` without `-t`), the prompt cannot be
answered and the task fails with exit code `205`. In a script, answer it with
`--yes`:

```bash
task --yes restore:latest
```

## Prometheus TSDB snapshot

Copying the files of a running Prometheus gives an inconsistent copy. The admin API
makes a consistent snapshot instead: hard links to the current blocks, in
`<storage.tsdb.path>/snapshots/<name>`. The admin API is off by default. Start
Prometheus with:

```text
--web.enable-admin-api
```

Without it, the POST answers HTTP `500` with
`{"status":"error","errorType":"unavailable","error":"admin APIs disabled"}`.
`curl -f` fails, and the task stops. The
same API can delete series, so do not expose port 9090 to people who should not have
it. Put Prometheus behind a proxy with authentication, or keep it on localhost.

```bash
task prometheus:snapshot PROM_DATA=/var/lib/prometheus
```

```text
task: [prometheus:snapshot] name=$(curl -fsS -X POST "http://localhost:9090/api/v1/admin/tsdb/snapshot" | jq -r .data.name)
...
snapshot 20261105T093000Z-4d1a9c5e2b7f3a60
wrote ./backups/prometheus-20261105-093000.tar.gz
```

- The API answers `{"status":"success","data":{"name":"20261105T093000Z-..."}}`.
  `jq -r .data.name` reads the name.
- The task must run on the Prometheus host, as a user that can read and delete
  `PROM_DATA/snapshots` (usually `prometheus` or root). It deletes the snapshot after
  archiving it, because the snapshot keeps old blocks on disk.
- The four shell lines are one command, so `name` is kept from line to line.
- `set: [pipefail]` makes `curl ... | jq` fail when `curl` fails. Without it, `jq`
  gets empty input, `name` is empty, and `tar` would archive the whole snapshots
  directory.

To restore, stop Prometheus, extract the archive, and put the snapshot's block
directories in an empty `storage.tsdb.path`. The details are in
[[observability/prometheus/backup]].

## Grafana dashboard export

The Grafana HTTP API returns each dashboard as JSON. The task needs a **service
account token**. Create a service account with the `Viewer` role: it can read every
dashboard and change nothing. In the UI: *Administration > Users and access > Service
accounts > Add service account*, then *Add service account token*. With the API, as
an admin:

```bash
SA_ID=$(curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" -H 'Content-Type: application/json' \
  -d '{"name":"backup","role":"Viewer"}' "$GRAFANA_URL/api/serviceaccounts" | jq -r .id)
GRAFANA_TOKEN=$(curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" -H 'Content-Type: application/json' \
  -d '{"name":"backup-task"}' "$GRAFANA_URL/api/serviceaccounts/$SA_ID/tokens" | jq -r .key)
export GRAFANA_TOKEN
```

Then:

```bash
task grafana:export GRAFANA_URL=https://grafana.example.com
```

```text
exported c2b7f0e1-0d8f-4e8a-9a5c-1f0e2d3c4b5a
wrote ./backups/grafana-20261105-093000.tar.gz
```

- `/api/search?type=dash-db` lists the dashboards. The `while` loop gets each one by
  its `uid` with `/api/dashboards/uid/<uid>`, and keeps the `.dashboard` part: the
  dashboard model, without Grafana's metadata.
- The token is read as `$GRAFANA_TOKEN` from the environment, not as
  `{{.GRAFANA_TOKEN}}`. A template is replaced before Task prints the command, so the
  token would appear in the output and in CI logs. `requires:` still checks that it is
  set, because environment variables count.
- `defer:` removes the temporary directory even when an export fails.
- This exports dashboards only. Data sources, folders, alert rules and users are
  separate API calls, and the Grafana database holds all of them. See
  [[observability/grafana/backup]].

To import a file back, wrap it and POST it:

```bash
jq '{dashboard: (.id = null), overwrite: true}' "$FILE" |
  curl -fsS -H "Authorization: Bearer $GRAFANA_ADMIN_TOKEN" -H 'Content-Type: application/json' \
    -d @- "$GRAFANA_URL/api/dashboards/db"
```

The import needs an `Editor` or `Admin` token, not the `Viewer` one.

## Run it from cron

```text
30 2 * * * cd /srv/backup && task backup:daily prometheus:snapshot >>/var/log/backup.log 2>&1
```

- `cd` first: Task looks for `Taskfile.yml` in the current directory and its parents.
- Cron has a short `PATH`. Use the full path to `task` if it is in `~/.local/bin`.
- `task` exits non-zero when a task fails, so the cron mail or your monitoring sees
  it. Add `-x` to get the failed command's own exit code instead of `201`.
- Put secrets such as `GRAFANA_TOKEN` in a file read by the job, not in the crontab
  line.

<!-- uplink -->
Part of [[dev/taskfile/index|Task (Taskfile)]].
