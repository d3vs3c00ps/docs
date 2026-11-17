---
title: Grafana troubleshooting
description: Fix data source errors, empty panels, login loops behind a reverse proxy, permission errors on /var/lib/grafana, SQLite "database is locked" and provisioning errors, and read the Grafana logs
tags: [observability, monitoring, grafana, troubleshooting]
type: reference
status: complete
---

# Grafana troubleshooting

Problems and fixes for Grafana 13.3.0, with the lab of
[[observability/grafana/quickstart]] (Grafana and Prometheus in Docker Compose).

## Read the logs first

```bash
docker compose logs --tail 100 grafana
```

On a host with the package: `journalctl -u grafana-server` and `/var/log/grafana/grafana.log`.

Each line has a `level` (`info`, `warn`, `error`) and a `logger` that names the part of
Grafana: `provisioning.datasources`, `provisioning.dashboard`, `sqlstore`, `ngalert`...
For more detail, set the level to `debug` and recreate the container:

```yaml
    environment:
      GF_LOG_LEVEL: debug
```

Debug logs are large. Go back to `info` when you are done.

The health endpoint needs no login. It says if the database answers:

```bash
curl -s http://localhost:3000/api/health
```

Use it for the health check of a load balancer or of `compose.yaml`.

## Data source errors

**The URL is `localhost`.** Inside the Grafana container, `localhost` is the container
itself, not your host and not Prometheus. A data source with `http://localhost:9090`
fails:

```bash
source .env
curl -s -u "admin:$GRAFANA_ADMIN_PASSWORD" http://localhost:3000/api/datasources/uid/prometheus-localhost/health
```

```json
{"message":"... dial tcp [::1]:9090: connect: connection refused ...","status":"ERROR"}
```

Use the Compose service name (`http://prometheus:9090`). When Prometheus runs on the
host, not in Compose, use `http://host.docker.internal:9090` and add this to the
`grafana` service:

```yaml
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

On a host with the package, `localhost` is right when Prometheus runs on the same host.

**"Bad Gateway" (HTTP 502).** Panels and Explore send the queries through the Grafana
server. When Grafana cannot reach the data source, it answers 502 Bad Gateway. Test the
connection from the Grafana container, not from your laptop:

```bash
docker compose exec grafana wget -qO- http://prometheus:9090/-/ready
```

Then check the DNS name, the port, the firewall, and for `https` the certificate (set
the CA in the data source, do not skip TLS verification).

**The data source is read-only.** A provisioned data source cannot be changed in the UI.
Change the YAML file and restart Grafana.

## Panels show "No data"

The query ran, and returned nothing. Check in this order:

1. **The time range.** The data may be outside it. Try **Last 24 hours**. A server whose
   clock is wrong stores samples at the wrong time (see
   [[observability/prometheus/troubleshooting#Time skew]]).
2. **The query in Prometheus.** Copy it to the Prometheus UI, or open **Explore** in
   Grafana. If Prometheus returns nothing too, the problem is the query or the data.
3. **A wrong label.** `up{job="nodes"}` instead of `up{job="node"}` returns nothing,
   without an error. Find the real values in Explore with the metrics browser, or with
   `label_values()`.
4. **The range of `rate()` is too short.** `rate(x[15s])` with a 15 s scrape interval
   has fewer than two samples in each window: no data. Use `$__rate_interval`, and set
   **Scrape interval** (`timeInterval`) on the data source.
5. **A variable is empty.** With `instance=~"$instance"`, an empty variable selects
   nothing. Check the drop-down at the top of the dashboard.

The **Query inspector** (panel menu, **Inspect > Query**) shows the query that Grafana
sent and the raw answer.

## Login loops and wrong links behind a reverse proxy

Behind a reverse proxy, Grafana must know its public URL. Without it, you get redirects
to the wrong place, a login page that comes back after each login, or broken links in
alert notifications.

Set `root_url` to the URL users type. When Grafana is under a sub-path, also set
`serve_from_sub_path`:

```yaml
    environment:
      GF_SERVER_ROOT_URL: http://localhost:8080/grafana/
      GF_SERVER_SERVE_FROM_SUB_PATH: "true"
```

The matching nginx configuration (`nginx.conf`, mounted at
`/etc/nginx/conf.d/default.conf`) keeps the path, and passes the `Host` header and the
WebSocket upgrade (used by Grafana Live):

```nginx
map $http_upgrade $connection_upgrade {
  default upgrade;
  ''      close;
}

server {
  listen 8080;

  location /grafana/ {
    proxy_pass http://grafana:3000;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
  }
}
```

The nginx service in `compose.yaml`:

```yaml
  nginx:
    image: nginx:1.29-alpine
    ports:
      - "8080:8080"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - grafana
```

`proxy_pass` has no path after the port: nginx sends `/grafana/...` to Grafana
unchanged, which is what `serve_from_sub_path` expects.

Other causes of a login loop:

- the session cookie is refused: Grafana is served over HTTP, but
  `GF_SECURITY_COOKIE_SECURE=true`; or the browser blocks the cookie of an `<iframe>`
  (`cookie_samesite`);
- several Grafana instances behind a load balancer use SQLite each: a session made on
  one is unknown to the others. Use a shared database
  ([[observability/grafana/advanced#External database: PostgreSQL or MySQL]]).

## Permission errors on /var/lib/grafana

The Grafana image runs as user ID **472**, group 0. With an empty bind mount owned by
root, Grafana cannot write and stops at once:

```text
GF_PATHS_DATA='/var/lib/grafana' is not writable.
You may have issues with file permissions, more information here: http://docs.grafana.org/installation/docker/#migrate-to-v51-or-later
mkdir: can't create directory '/var/lib/grafana/plugins': Permission denied
```

If the folder already has a `grafana.db` but the folder itself is not writable,
Grafana prints the first line, starts, and then stops with
`attempt to write a readonly database`: SQLite must create its journal next to the file.

With `restart: unless-stopped`, Docker starts it again and again: `docker compose ps`
shows `Restarting (1)` or a short `Up` time, and
`docker inspect -f '{{.RestartCount}}'` goes up.

Fix the owner of the folder on the host:

```bash
sudo chown -R 472:0 ./grafana-data
```

Or run the container as your own user (`user: "1000"` in `compose.yaml`), with a folder
that belongs to that user. A named volume, as in the quickstart, does not have this
problem: Docker gives it the owner from the image.

## "database is locked"

SQLite allows one writer at a time. With many users, alert rules and API scripts at
once, Grafana can log `database is locked` and some saves fail. Also check that two
Grafana containers do not share one `grafana.db` (each must have its own, or use
PostgreSQL), and that the file is not on NFS or another network file system.

Fixes, from the smallest:

- turn on the SQLite write-ahead log (WAL) mode, which lets reads and one write work
  together:

```yaml
    environment:
      GF_DATABASE_WAL: "true"
```

- move to PostgreSQL or MySQL
  ([[observability/grafana/advanced#External database: PostgreSQL or MySQL]]).

## Provisioning errors

Grafana reads the provisioning files at start. The effect of an error depends on the
type:

- a broken **data source** file stops Grafana, after a minute or so: the container
  exits with code 1 (with a restart policy, Docker starts it again and again), and
  the logs say `Datasource provisioning error`;
- a broken **dashboard** JSON file is skipped: Grafana starts, logs the error with
  `logger=provisioning.dashboard`, and the dashboard is missing.

Find them:

```bash
docker compose logs grafana | grep -i 'provisioning' | grep -E 'level=(error|warn)'
```

Check the YAML and JSON before a restart, for example with `yq` and `jq`:

```bash
jq empty grafana/dashboards/*.json
```

`jq empty` prints nothing for a good file, and the line of the error for a bad one.

## See also

- [[observability/prometheus/troubleshooting]]
- [[observability/grafana/backup]]

<!-- uplink -->
Part of [[observability/grafana/index|Grafana]].
