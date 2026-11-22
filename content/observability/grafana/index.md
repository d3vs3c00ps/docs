---
title: "Grafana"
description: "Install Grafana, provision data sources and dashboards as code, back it up, and debug it."
tags: [grafana]
type: moc
status: complete
---

<!-- generated-moc -->

# Grafana

Install Grafana, provision data sources and dashboards as code, back it up, and debug it.


| Note | | What it covers |
| --- | --- | --- |
| [[observability/grafana/advanced\|Grafana advanced configuration]] | reference | Provision dashboards from files, use variables, drive Grafana with the HTTP API and service account tokens, provision alerting, use PostgreSQL, map grafana.ini to GF_ variables, choose authentication and install plugins |
| [[observability/grafana/backup\|Grafana backup and restore]] | how-to | Back up the Grafana SQLite database consistently, export and re-import every dashboard as JSON through the HTTP API, restore and verify, and why dashboards as code is the best backup |
| [[observability/grafana/quickstart\|Grafana quickstart]] | how-to | Run Grafana next to Prometheus with Docker Compose, set the admin password, provision the Prometheus data source, import a dashboard and build a first panel |
| [[observability/grafana/troubleshooting\|Grafana troubleshooting]] | reference | Fix data source errors, empty panels, login loops behind a reverse proxy, permission errors on /var/lib/grafana, SQLite "database is locked" and provisioning errors, and read the Grafana logs |

Part of [[observability/index|Observability]].
