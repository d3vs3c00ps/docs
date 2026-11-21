---
title: Grafana backup and restore
description: Back up the Grafana SQLite database consistently, export and re-import every dashboard as JSON through the HTTP API, restore and verify, and why dashboards as code is the best backup
tags: [observability, monitoring, grafana, backup, sqlite]
type: howto
status: complete
---

# Grafana backup and restore

This note uses the lab of [[observability/grafana/quickstart]] (Grafana 13.3.0 in Docker
Compose, SQLite database). For a general view of backups, see backup.

## What to back up

| What | Where (container / package) | How |
| --- | --- | --- |
| the database: users, dashboards, folders, alert rules, data sources made in the UI | `/var/lib/grafana/grafana.db` (SQLite) | a consistent copy, below; or the backup of PostgreSQL/MySQL |
| the configuration | environment variables in `compose.yaml`, or `/etc/grafana/grafana.ini` | git |
| provisioning files and dashboard JSON files | `./grafana/provisioning`, `./grafana/dashboards` | git |
| plugins | `/var/lib/grafana/plugins` | nothing: list them in `GF_PLUGINS_PREINSTALL` and they come back |
| the secret key | `[security] secret_key` (`GF_SECURITY_SECRET_KEY`) | your secret store |

> [!warning] The secret key
> Grafana encrypts data source passwords and other secrets in the database with
> `secret_key`. A restored database with another key cannot decrypt them: the data
> sources fail until you type the passwords again. If you changed the key, back it up
> with the database. Provisioned data sources do not have this problem: their secrets
> come from the files.

## Copy the SQLite database

A plain `cp` of `grafana.db` while Grafana writes can give a broken copy. Two safe ways.

**Stop Grafana, then copy the whole data folder.** Simple, with a short downtime:

```bash
mkdir -p backup
docker compose stop grafana
docker compose run --rm --no-deps --user root -v "$PWD/backup:/backup" \
  --entrypoint sh grafana -c 'tar -czf /backup/grafana-data.tar.gz -C /var/lib/grafana .'
docker compose start grafana
```

**Online, with `sqlite3 .backup`.** SQLite copies the database page by page, in a
consistent state, while Grafana runs. The Grafana image has no `sqlite3`, so run it in a
small container that shares the volume:

```bash
mkdir -p backup
docker run --rm --volumes-from "$(docker compose ps -q grafana)" -v "$PWD/backup:/backup" \
  alpine:3.22 sh -c 'apk add --no-cache sqlite >/dev/null &&
    sqlite3 /var/lib/grafana/grafana.db ".backup /backup/grafana.db" &&
    sqlite3 /backup/grafana.db "PRAGMA integrity_check"'
```

It prints `ok` when the copy is sound. On a host with the package, it is one line:
`sqlite3 /var/lib/grafana/grafana.db ".backup '/backup/grafana.db'"`.

With PostgreSQL or MySQL ([[observability/grafana/advanced#External database: PostgreSQL or MySQL]]),
back up the database with `pg_dump` or `mysqldump` instead.

## Restore the database

Stop Grafana, put the file back, give it to user 472, start:

```bash
docker compose stop grafana
docker compose run --rm --no-deps --user root -v "$PWD/backup:/backup:ro" \
  --entrypoint sh grafana -c \
  'cp /backup/grafana.db /var/lib/grafana/grafana.db && rm -f /var/lib/grafana/grafana.db-wal /var/lib/grafana/grafana.db-shm && chown 472:0 /var/lib/grafana/grafana.db'
docker compose start grafana
```

Remove the `-wal` and `-shm` files if they exist: they belong to the old database.

Verify: the health endpoint, a login, and a dashboard you know:

```bash
source .env
curl -s http://localhost:3000/api/health | jq -r .database
curl -s -u "admin:$GRAFANA_ADMIN_PASSWORD" 'http://localhost:3000/api/search?type=dash-db' | jq -r '.[].title'
```

Restore into the same Grafana version. A newer version migrates the database at start.
Do not restore into an older version: it does not know the newer schema. (Only the
same version is tested here.)

## Export all dashboards with the API

A database backup restores everything or nothing. JSON exports let you restore one
dashboard, move dashboards to another Grafana (or from SQLite to PostgreSQL), and see
changes with `diff`.

Use a service account token with the `Viewer` role to export, `Editor` to import (see
[[observability/grafana/advanced#The HTTP API and service accounts]]):

```bash
G=http://localhost:3000
AUTH="Authorization: Bearer $TOKEN"
FILTER='select(.meta.provisioned | not)
  | {dashboard: (.dashboard | .id = null), folderUid: .meta.folderUid, overwrite: true}'
mkdir -p export/dashboards
curl -s -H "$AUTH" "$G/api/folders" | jq '[.[] | {uid, title}]' >export/folders.json
curl -s -H "$AUTH" "$G/api/search?type=dash-db&limit=5000" | jq -r '.[].uid' |
  while read -r uid; do
    curl -s -H "$AUTH" "$G/api/dashboards/uid/$uid" | jq "$FILTER" >"export/dashboards/$uid.json"
  done
find export/dashboards -type f -empty -delete
ls export/dashboards
```

- Each file is ready to import: the dashboard, its folder, and `overwrite: true`.
- `.id = null`: the numeric `id` is local to one Grafana; the `uid` is the stable name.
- Provisioned dashboards are left out: they come from files already, and Grafana
  refuses to overwrite them through the API.
- `/api/folders` lists the top-level folders. For nested folders, call it again with
  `?parentUid=<uid>`.

## Re-import the dashboards

Create the folders first, then import every file:

```bash
jq -c '.[]' export/folders.json | while read -r folder; do
  curl -s -H "$AUTH" -H 'Content-Type: application/json' -X POST "$G/api/folders" -d "$folder" >/dev/null
done
for f in export/dashboards/*.json; do
  curl -s -H "$AUTH" -H 'Content-Type: application/json' -X POST "$G/api/dashboards/db" -d @"$f" \
    | jq -r '"\(.status) \(.uid)"'
done
```

Each import prints `success <uid>`. A folder that exists already gives an error that
you can ignore. With `overwrite: true`, an existing dashboard with the same `uid` is
replaced.

## Dashboards as code: the best backup

The best backup is not to need one. Keep dashboards, data sources and alert rules as
files in git, and load them with provisioning
([[observability/grafana/advanced#Provision dashboards from files]]). Then:

- a new Grafana gets everything from the repository, in seconds;
- every change is reviewed and can be reverted;
- the database holds only users, preferences and ad-hoc dashboards. Back it up, but its
  loss is a small problem.

Tools that generate dashboards from code (Grafonnet in Jsonnet, the Grafana Foundation
SDK, Terraform's Grafana provider) go one step further.

## See also

- [[observability/prometheus/backup]]
- [[observability/grafana/troubleshooting]]

<!-- uplink -->
Part of [[observability/grafana/index|Grafana]].
