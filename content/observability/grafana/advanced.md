---
title: Grafana advanced configuration
description: Provision dashboards from files, use variables, drive Grafana with the HTTP API and service account tokens, provision alerting, use PostgreSQL, map grafana.ini to GF_ variables, choose authentication and install plugins
tags: [observability, monitoring, grafana, alerting, provisioning]
type: reference
status: complete
---

# Grafana advanced configuration

This note builds on the lab of [[observability/grafana/quickstart]] (Grafana 13.3.0 and
Prometheus 3.15.1 in Docker Compose). Each section adds files or settings to it.

## Provision dashboards from files

Dashboards made in the UI live only in the Grafana database. Dashboards as files can
be reviewed in git, and every Grafana gets the same ones. A *provider* file tells
Grafana where to find them.

Mount the provisioning folders for dashboards and alerting, and the folder of the
dashboard files. The `volumes` of the `grafana` service in `compose.yaml` become:

```yaml
    volumes:
      - grafana-data:/var/lib/grafana
      - ./grafana/provisioning/datasources:/etc/grafana/provisioning/datasources:ro
      - ./grafana/provisioning/dashboards:/etc/grafana/provisioning/dashboards:ro
      - ./grafana/provisioning/alerting:/etc/grafana/provisioning/alerting:ro
      - ./grafana/dashboards:/etc/grafana/dashboards:ro
```

`grafana/provisioning/dashboards/infrastructure.yaml`:

```yaml
apiVersion: 1

providers:
  - name: infrastructure
    orgId: 1
    folder: Infrastructure
    folderUid: infrastructure
    type: file
    disableDeletion: false
    allowUiUpdates: false
    updateIntervalSeconds: 30
    options:
      path: /etc/grafana/dashboards
```

| Key | Meaning |
| --- | --- |
| `folder`, `folderUid` | the folder for the dashboards of this provider. Grafana creates it |
| `allowUiUpdates` | `false`: the UI cannot save changes; you change the file. `true`: the UI can save, but the file wins again when it changes |
| `disableDeletion` | `false`: when you delete the file, Grafana deletes the dashboard |
| `updateIntervalSeconds` | how often Grafana reads the folder again |
| `options.foldersFromFilesStructure` | `true`: sub-folders on disk become Grafana folders (then leave `folder` empty) |

Put dashboard JSON files in `grafana/dashboards/`. Get the JSON from a dashboard made
in the UI: **Edit > Settings > JSON Model**, or **Export > Export as JSON** (choose the
classic format; the "V2 resource" format needs the other provisioning syntax). Then
set a fixed `uid` and remove `id`.

`grafana/dashboards/node-overview.json`:

```json
{
  "uid": "node-overview",
  "title": "Node overview",
  "tags": ["node", "provisioned"],
  "schemaVersion": 41,
  "time": { "from": "now-1h", "to": "now" },
  "templating": {
    "list": [
      {
        "name": "instance",
        "label": "Instance",
        "type": "query",
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "query": {
          "qryType": 1,
          "query": "label_values(up{job=\"node\"}, instance)",
          "refId": "PrometheusVariableQueryEditor-VariableQuery"
        },
        "definition": "label_values(up{job=\"node\"}, instance)",
        "refresh": 2,
        "multi": true,
        "includeAll": true
      }
    ]
  },
  "panels": [
    {
      "id": 1,
      "type": "timeseries",
      "title": "CPU used",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100 }, "overrides": [] },
      "targets": [
        {
          "refId": "A",
          "expr": "100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\", instance=~\"$instance\"}[$__rate_interval])))",
          "legendFormat": "{{instance}}"
        }
      ]
    },
    {
      "id": 2,
      "type": "timeseries",
      "title": "Memory used",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100 }, "overrides": [] },
      "targets": [
        {
          "refId": "A",
          "expr": "100 * (1 - node_memory_MemAvailable_bytes{instance=~\"$instance\"} / node_memory_MemTotal_bytes{instance=~\"$instance\"})",
          "legendFormat": "{{instance}}"
        }
      ]
    }
  ]
}
```

Restart Grafana (`docker compose up -d`) to load a new provider. After that, new and
changed JSON files are read every `updateIntervalSeconds`.

> [!note] Dashboards v2 and Git Sync
> Grafana 12 and 13 also have a new dashboard format ("V2 resource",
> `apiVersion: dashboard.grafana.app/...`) and Git Sync, which syncs dashboards with a
> Git repository from the UI. Classic JSON files, as above, still work in Grafana 13.

## Variables and templating

A variable makes one dashboard work for many hosts, jobs or environments. It shows as
a drop-down at the top of the dashboard. In the queries, `$instance` is replaced by the
selected value.

The dashboard above has one variable, `instance`. Its query `label_values(up{job="node"},
instance)` lists the values of the `instance` label. Other Prometheus variable queries:

| Query | Returns |
| --- | --- |
| `label_values(job)` | every value of the label `job` |
| `label_values(up{job="node"}, instance)` | the `instance` values of the series that match |
| `query_result(topk(5, sum by (instance) (rate(node_cpu_seconds_total[5m]))))` | the result of a query (extract the value with a regex) |

- With `multi` or `includeAll`, the value can be several items. Always use `=~`
  in the query: `instance=~"$instance"`.
- `refresh: 2` updates the list when the time range changes (`1`: when the dashboard
  loads).
- Grafana also has built-in variables: `$__rate_interval`, `$__interval`, `$__range`.

Grafana runs the variable query through the data source. You can see the same call
with the API:

```bash
source .env
curl -s -u "admin:$GRAFANA_ADMIN_PASSWORD" -G \
  http://localhost:3000/api/datasources/uid/prometheus/resources/api/v1/label/instance/values \
  --data-urlencode 'match[]=up{job="node"}' | jq -c .data
```

## The HTTP API and service accounts

Everything in the UI is also in the HTTP API. For scripts and CI, do not use the admin
password: create a **service account** with the smallest role, and give it a token.

```bash
source .env
G=http://localhost:3000
SA_ID=$(curl -s -u "admin:$GRAFANA_ADMIN_PASSWORD" -H 'Content-Type: application/json' \
  -X POST "$G/api/serviceaccounts" -d '{"name": "automation", "role": "Editor"}' | jq .id)
TOKEN=$(curl -s -u "admin:$GRAFANA_ADMIN_PASSWORD" -H 'Content-Type: application/json' \
  -X POST "$G/api/serviceaccounts/$SA_ID/tokens" \
  -d '{"name": "automation-token", "secondsToLive": 2592000}' | jq -r .key)
echo "$TOKEN"
```

- The token starts with `glsa_`. Grafana shows it only once: store it in your secret
  store.
- The name is unique. Run the block twice and the first call fails with
  `service account already exists`: `SA_ID` is then `null`, and so is the token. Add
  another token to the existing account instead.
- `secondsToLive: 2592000` is 30 days. `0` means it never expires.
- The roles are `Viewer`, `Editor` and `Admin`. A `Viewer` token can read, but cannot
  create a folder (`403 Access denied`).

Use the token with `Authorization: Bearer`:

```bash
# list the dashboards: uid, title, folder
curl -s -H "Authorization: Bearer $TOKEN" "$G/api/search?type=dash-db" \
  | jq -r '.[] | [.uid, .title, .folderTitle] | @tsv'

# create a folder
curl -s -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -X POST "$G/api/folders" -d '{"uid": "team-a", "title": "Team A"}' | jq -r .url

# run a query like a panel does
curl -s -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -X POST "$G/api/ds/query" \
  -d '{"from": "now-5m", "to": "now", "queries": [{"refId": "A", "datasource": {"uid": "prometheus"}, "expr": "up"}]}' \
  | jq '.results.A.frames | length'
```

> [!note] `/api` and `/apis`
> Since Grafana 13, the legacy `/api/...` endpoints are deprecated in favour of the
> Kubernetes-style `/apis/...` API, for example
> `/apis/dashboard.grafana.app/v1/namespaces/default/dashboards`. The legacy endpoints
> still work and are not being removed now, but get no new features.

## Alerting in Grafana

Grafana has its own alerting: rules that query any data source, contact points, and
notification policies. It is an alternative to Prometheus rules with Alertmanager (see
[[observability/prometheus/advanced#Alertmanager]]). Pick one place for your alerts.

All three can be provisioned from files in `grafana/provisioning/alerting/`.
`grafana/provisioning/alerting/node.yaml`:

```yaml
apiVersion: 1

contactPoints:
  - orgId: 1
    name: ops-webhook
    receivers:
      - uid: ops-webhook
        type: webhook
        settings:
          url: http://chat-bridge.internal.example.com:8080/grafana
          httpMethod: POST

policies:
  - orgId: 1
    receiver: ops-webhook
    group_by: [grafana_folder, alertname]
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 4h

groups:
  - orgId: 1
    name: node
    folder: Alerts
    interval: 1m
    rules:
      - uid: node-down
        title: NodeDown
        condition: C
        data:
          - refId: A
            relativeTimeRange: { from: 300, to: 0 }
            datasourceUid: prometheus
            model:
              refId: A
              expr: up{job="node"}
              instant: true
          - refId: C
            datasourceUid: __expr__
            model:
              refId: C
              type: threshold
              expression: A
              conditions:
                - evaluator: { type: lt, params: [1] }
        for: 2m
        noDataState: Alerting
        execErrState: Error
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.instance }} is down"
```

- A rule has queries (`A`, from Prometheus) and expressions (`C`, a threshold on `A`).
  `condition` names the one that decides.
- `noDataState: Alerting` fires when the query returns nothing, for example when the
  job disappears.
- The `policies` file replaces the **whole** notification policy tree.
- Provisioned rules, contact points and policies are read-only in the UI.

Grafana reads these files at start: `docker compose restart grafana`. Check what it
loaded:

```bash
curl -s -u "admin:$GRAFANA_ADMIN_PASSWORD" http://localhost:3000/api/v1/provisioning/alert-rules \
  | jq -r '.[] | [.uid, .title, .provenance] | @tsv'
curl -s -u "admin:$GRAFANA_ADMIN_PASSWORD" http://localhost:3000/api/prometheus/grafana/api/v1/rules \
  | jq -r '.data.groups[].rules[] | [.name, .state, .health] | @tsv'
```

To write the YAML, build the rule in the UI first, then **More > Export** gives the
provisioning format.

## External database: PostgreSQL or MySQL

The default SQLite database is a file in `/var/lib/grafana`. It is fine for one Grafana
instance. Use PostgreSQL or MySQL when:

- you run two or more Grafana instances behind a load balancer (high availability):
  they must share one database;
- you have many users and dashboards, or you see `database is locked` errors;
- you want the database in your normal database backups.

Add PostgreSQL to `compose.yaml`, and give Grafana the connection. The password comes
from a file (a Compose secret), not from an environment variable:

```yaml
services:
  postgres:
    image: postgres:17-alpine
    environment:
      POSTGRES_DB: grafana
      POSTGRES_USER: grafana
      POSTGRES_PASSWORD_FILE: /run/secrets/grafana_db_password
    secrets:
      - grafana_db_password
    volumes:
      - postgres-data:/var/lib/postgresql/data

  grafana:
    environment:
      GF_DATABASE_TYPE: postgres
      GF_DATABASE_HOST: postgres:5432
      GF_DATABASE_NAME: grafana
      GF_DATABASE_USER: grafana
      GF_DATABASE_PASSWORD__FILE: /run/secrets/grafana_db_password
    secrets:
      - grafana_db_password
    depends_on:
      - postgres

secrets:
  grafana_db_password:
    file: ./secrets/grafana_db_password

volumes:
  postgres-data:
```

Put this in `compose.override.yaml`, or merge it into `compose.yaml`. Create the
password file:

```bash
mkdir -p secrets
openssl rand -base64 24 >secrets/grafana_db_password
chmod 644 secrets/grafana_db_password
docker compose up -d
```

The file must be readable by the users of both containers (UID 70 for postgres, 472 for
Grafana). Grafana creates its tables at the first start. It does **not** copy the
SQLite data: a new database starts empty. Move dashboards with the API (see
[[observability/grafana/backup#Export all dashboards with the API]]).

## grafana.ini and GF_ variables

Every setting of `grafana.ini` can be set with an environment variable:
`GF_<SECTION>_<KEY>`, in upper case, with `.` and `-` replaced by `_`.

| grafana.ini | Environment variable |
| --- | --- |
| `[server]` `root_url` | `GF_SERVER_ROOT_URL` |
| `[security]` `admin_password` | `GF_SECURITY_ADMIN_PASSWORD` |
| `[database]` `type` | `GF_DATABASE_TYPE` |
| `[auth.anonymous]` `enabled` | `GF_AUTH_ANONYMOUS_ENABLED` |
| `[log]` `level` | `GF_LOG_LEVEL` |
| `[plugins]` `preinstall_sync` | `GF_PLUGINS_PREINSTALL_SYNC` |

- Add `__FILE` to the name to read the value from a file: `GF_DATABASE_PASSWORD__FILE`.
- In `grafana.ini` itself, `$__env{NAME}` and `$__file{/path}` do the same.
- The environment wins over `grafana.ini`. **Administration > General > Settings**
  (or `/api/admin/settings`) shows the result.

In containers, prefer the variables, and keep `grafana.ini` as shipped. On a host with
the package, edit `/etc/grafana/grafana.ini` and restart `grafana-server`.

## Authentication

Grafana has its own users and passwords by default. In a company, connect it to the
central identity system instead. **OAuth 2.0 / OpenID Connect** works with Keycloak,
Entra ID (Azure AD), Okta, Google, GitHub and GitLab (`[auth.generic_oauth]` and the
provider sections); it can map groups to Grafana roles. **LDAP** (`[auth.ldap]` and
`ldap.toml`) works with Active Directory and OpenLDAP. **Auth proxy** trusts a header
set by a reverse proxy that does the login. **Anonymous access**
(`[auth.anonymous]`) shows dashboards without login, for a wall screen in a trusted
network. Whatever you choose, keep one local admin account with a strong password for
emergencies, and set `[users] allow_sign_up = false` (the default).

## Plugins

Panels and data sources not in the core come as plugins, from the Grafana catalog.

With Docker, list them in an environment variable. Grafana installs them at start:

```yaml
    environment:
      GF_PLUGINS_PREINSTALL_SYNC: grafana-clock-panel
```

- `GF_PLUGINS_PREINSTALL_SYNC` installs **before** Grafana starts. Use it when a
  provisioned dashboard or data source needs the plugin.
- `GF_PLUGINS_PREINSTALL` installs in the background: Grafana starts faster, but the
  plugin is there a bit later.
- Pin a version with `id@version`, for example `grafana-clock-panel@3.1.0`. Without a
  version, Grafana updates the plugin at start.
- The old `GF_INSTALL_PLUGINS` variable of the Docker image is deprecated. The image
  prints `GF_INSTALL_PLUGINS is deprecated` at start: use the variables above.

With the CLI, then restart Grafana:

```bash
docker compose exec grafana grafana cli plugins install grafana-clock-panel
docker compose restart grafana
docker compose exec grafana grafana cli plugins ls
```

The plugins go to `/var/lib/grafana/plugins`, in the data volume. Grafana needs to
reach `grafana.com` to install them. Without internet access, download the zip and use
`--pluginUrl`.

## See also

- [[observability/grafana/backup]]
- [[observability/grafana/troubleshooting]]
- [[observability/prometheus/advanced]]

<!-- uplink -->
Part of [[observability/grafana/index|Grafana]].
