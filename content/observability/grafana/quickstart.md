---
title: Grafana quickstart
description: Run Grafana next to Prometheus with Docker Compose, set the admin password, provision the Prometheus data source, import a dashboard and build a first panel
tags: [observability, monitoring, grafana, prometheus, docker]
type: howto
status: complete
---

# Grafana quickstart

Grafana shows data as dashboards. It does not store metrics itself: it queries *data
sources* such as Prometheus, Loki, PostgreSQL or Elasticsearch. Grafana stores its own
objects (users, dashboards, folders, alert rules) in a small database, SQLite by
default.

This note adds Grafana to the lab of [[observability/prometheus/quickstart]]. For
Kubernetes, see [[kubernetes/observability/prometheus-stack]] and
[[kubernetes/observability/metrology/quickstart]].

Versions: Grafana 13.3.0, Prometheus 3.15.1, node_exporter 1.12.1.

## Run it with Docker Compose

The project folder:

```text
.
├── .env
├── compose.yaml
├── prometheus.yml
└── grafana/
    └── provisioning/
        └── datasources/
            └── prometheus.yaml
```

`prometheus.yml` is the one of the [[observability/prometheus/quickstart#Run it with Docker Compose|Prometheus quickstart]].

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
    restart: unless-stopped

  grafana:
    image: grafana/grafana:13.3.0
    ports:
      - "3000:3000"
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD:?set GRAFANA_ADMIN_PASSWORD in .env}
    volumes:
      - grafana-data:/var/lib/grafana
      - ./grafana/provisioning/datasources:/etc/grafana/provisioning/datasources:ro
    depends_on:
      - prometheus
    restart: unless-stopped

volumes:
  prometheus-data:
  grafana-data:
```

- `grafana-data` holds the SQLite database (`grafana.db`), the installed plugins and
  other state. Without a volume, you lose your dashboards when the container is
  recreated.
- Only the `datasources` folder is mounted. If you mount the whole
  `provisioning` folder, it hides the empty sub-folders of the image, and Grafana logs
  an error for each missing one (`can't read alerting provisioning files from
  directory`).
- The container runs as user ID 472. A bind-mounted data folder must be writable by
  it (see [[observability/grafana/troubleshooting#Permission errors on /var/lib/grafana]]).
- `${GRAFANA_ADMIN_PASSWORD:?...}` makes Compose stop with this message when the
  variable is not set.

`.env`, next to `compose.yaml` (Compose reads it by itself). Do not commit it:

```bash
GRAFANA_ADMIN_PASSWORD=change-me-now
```

## Provision the Prometheus data source

You can add a data source in the UI (**Connections > Data sources**). A file is better:
it is in git, and a new Grafana gets the same data source. Grafana reads the files in
`/etc/grafana/provisioning/datasources/` at start.

`grafana/provisioning/datasources/prometheus.yaml`:

```yaml
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
    jsonData:
      timeInterval: 15s
```

- `url` is seen **from the Grafana container**: use the Compose service name
  `prometheus`, not `localhost` (see
  [[observability/grafana/troubleshooting#Data source errors]]).
- `access: proxy` means the Grafana server sends the queries, not your browser.
- A fixed `uid` lets dashboards and alert rules refer to this data source on every
  Grafana.
- `timeInterval` is the Prometheus scrape interval. Grafana uses it to compute
  `$__rate_interval`.

Start everything:

```bash
docker compose up -d
curl -s http://localhost:3000/api/health
```

`/api/health` answers `{"database": "ok", "version": "13.3.0", ...}`.

Check the data source from the API:

```bash
source .env
curl -s -u "admin:$GRAFANA_ADMIN_PASSWORD" http://localhost:3000/api/datasources/uid/prometheus/health
```

```json
{"message":"Successfully queried the Prometheus API.","status":"OK"}
```

## First login and the admin password

Open `http://localhost:3000` and log in as `admin` with the password from `.env`.

`GF_SECURITY_ADMIN_PASSWORD` is used **only once**, when Grafana creates its database.
Changing it later in `.env` does nothing. To change the password, use the UI (the
profile menu, **Change password**) or the CLI in the container:

```bash
docker compose exec grafana grafana cli admin reset-admin-password 'a-new-long-password'
```

It prints `Admin password changed successfully ✔`. The CLI writes to the database
directly: it also works when you have lost the old password. Then update `.env`, so
the next person does not try the old value.

> [!note] grafana-cli
> Older guides use `grafana-cli`. The current command is `grafana cli` (one binary,
> two words). The Grafana 13 image has only `grafana`: `grafana-cli` gives
> `executable file not found`.

## Import a dashboard

grafana.com has thousands of community dashboards. "Node Exporter Full" (ID 1860) shows
everything node_exporter exposes.

In the UI: **Dashboards > New > Import**, type `1860`, **Load**, select the
`Prometheus` data source, **Import**.

The same with the API, which you can put in a script:

```bash
source .env
curl -s https://grafana.com/api/dashboards/1860/revisions/latest/download -o node-exporter-full.json
jq '{dashboard: ., overwrite: true, folderUid: ""}' node-exporter-full.json \
  | curl -s -u "admin:$GRAFANA_ADMIN_PASSWORD" -H 'Content-Type: application/json' \
      -X POST http://localhost:3000/api/dashboards/import -d @- \
  | jq -r '.importedUrl'
```

The command prints the path of the new dashboard, like `/d/rYdddlPWk/node-exporter-full`.

This dashboard picks its data source with a variable (`ds_prometheus`, of type
*data source*), which lists every Prometheus data source and starts on the default one.
Older community dashboards use a placeholder instead: a `__inputs` list with an entry
such as `DS_PROMETHEUS`, and `"uid": "${DS_PROMETHEUS}"` in the panels. For those, add
`inputs` to the body, to replace the placeholder with the `uid` of your data source:

```bash
jq '{dashboard: ., overwrite: true, folderUid: "",
     inputs: [{name: "DS_PROMETHEUS", type: "datasource", pluginId: "prometheus", value: "prometheus"}]}' \
  old-dashboard.json \
  | curl -s -u "admin:$GRAFANA_ADMIN_PASSWORD" -H 'Content-Type: application/json' \
      -X POST http://localhost:3000/api/dashboards/import -d @- \
  | jq -r '.importedUrl'
```

Review a community dashboard before you rely on it: some are old, and use metric
names that changed.

## A first panel

1. **Dashboards > New > New dashboard > Add visualization**, choose `Prometheus`.
2. In the query editor, switch from **Builder** to **Code**, and type:

   ```promql
   100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[$__rate_interval])))
   ```

3. **Options > Legend**: `{{instance}}`.
4. In the panel options on the right: **Title** `CPU used`, **Standard options > Unit**
   `Percent (0-100)`.
5. **Save dashboard**.

`$__rate_interval` is a Grafana variable. It is at least four scrape intervals, and
grows when you zoom out. Use it in every `rate()` in Grafana instead of a fixed `[5m]`.

The panel is stored as JSON in the dashboard. **Edit > Settings > JSON Model** shows it.
To keep dashboards in git, provision them from files: see
[[observability/grafana/advanced#Provision dashboards from files]].

## Install from the package repository

On a server without Docker, install the package from the Grafana repository. On RHEL,
Rocky Linux or Fedora:

```bash
cat >/etc/yum.repos.d/grafana.repo <<'EOF'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF
dnf install -y grafana-13.3.0
systemctl enable --now grafana-server
curl -s http://localhost:3000/api/health
```

- The service is `grafana-server`. The configuration is `/etc/grafana/grafana.ini`, the
  data is in `/var/lib/grafana`, the logs in `/var/log/grafana`.
- The provisioning folder is `/etc/grafana/provisioning`, as in the container.
- For Debian and Ubuntu, the APT repository is `https://apt.grafana.com`. Follow the
  [Grafana documentation](https://grafana.com/docs/grafana/latest/setup-grafana/installation/debian/).

## Next steps

- [[observability/grafana/advanced]]: dashboards as code, variables, the API, alerting.
- [[observability/grafana/backup]]
- [[observability/grafana/troubleshooting]]

<!-- uplink -->
Part of [[observability/grafana/index|Grafana]].
