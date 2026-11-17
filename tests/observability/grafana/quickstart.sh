#!/usr/bin/env bash
# note: observability/grafana/quickstart.md
# env: compose
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=observability/grafana/quickstart
G=http://localhost:3000
run() { bash -ec "$(note_block "$NOTE" "$1" "${2:-1}")"; }

section "Run it with Docker Compose"
tree=$(note_block "$NOTE" "Run it with Docker Compose" 1)
note_block "$NOTE" "Run it with Docker Compose" 2 >compose.yaml
note_block observability/prometheus/quickstart "Run it with Docker Compose" 2 >prometheus.yml
mkdir -p grafana/provisioning/datasources
note_block "$NOTE" "Provision the Prometheus data source" 1 >grafana/provisioning/datasources/prometheus.yaml
for f in .env compose.yaml prometheus.yml prometheus.yaml; do
  assert_match "the tree lists $f" "$f" "$tree"
done
check_output "the Grafana image is the version of versions.env" "grafana/grafana:$GRAFANA_VERSION" cat compose.yaml
check_output "without .env, Compose stops with the note's message" 'set GRAFANA_ADMIN_PASSWORD in .env' \
  bash -c 'docker compose config -q 2>&1; true'
check_fails "and fails" docker compose config -q
note_block "$NOTE" "Run it with Docker Compose" 3 >.env
check "with .env, the file is valid" docker compose config -q

section "Provision the Prometheus data source"
out=$(bash -ec "$(note_block "$NOTE" "Provision the Prometheus data source" 2 | sed 's|^curl|for i in $(seq 90); do curl -fs http://localhost:3000/api/health >/dev/null \&\& break; sleep 1; done; curl|')" 2>/dev/null)
assert_match "/api/health answers database ok (from the note)" '"database": "ok"' "$out"
assert_match "and the version" "\"version\": \"$GRAFANA_VERSION\"" "$out"
check_output "the data source works (from the note)" '"status":"OK"' run "Provision the Prometheus data source" 3
check_output "with the note's message" 'Successfully queried the Prometheus API' run "Provision the Prometheus data source" 3
# shellcheck source=/dev/null
source .env
check_output "the data source is the default, read-only (provisioned)" '"isDefault":true.*"readOnly":true|"readOnly":true.*"isDefault":true' \
  curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" "$G/api/datasources/uid/prometheus"
check_output "only datasources is mounted: no provisioning errors in the logs" '^$' \
  bash -c "docker compose logs grafana 2>&1 | grep -E 'level=(error|crit)' | grep -i provisioning || true"

section "First login and the admin password"
check_output "login with the password from .env" '"login":"admin"' curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" "$G/api/user"
check_output "a wrong password is refused" '^401$' curl -s -o /dev/null -w '%{http_code}' -u admin:wrong "$G/api/user"
check_output "reset-admin-password (from the note)" 'Admin password changed successfully' run "First login and the admin password" 1
check_output "the new password works" '"login":"admin"' curl -fsS -u "admin:a-new-long-password" "$G/api/user"
check_output "the old one no longer" '^401$' curl -s -o /dev/null -w '%{http_code}' -u "admin:$GRAFANA_ADMIN_PASSWORD" "$G/api/user"
echo 'GRAFANA_ADMIN_PASSWORD=yet-another-one' >.env
docker compose up -d --force-recreate grafana 2>/dev/null
wait_http "$G/api/health" 90
check_output "changing the variable later does nothing: the new value is refused" '^401$' \
  curl -s -o /dev/null -w '%{http_code}' -u "admin:yet-another-one" "$G/api/user"
check_output "the password from the CLI still works" '"login":"admin"' curl -fsS -u "admin:a-new-long-password" "$G/api/user"
check_output "grafana-cli is not in the Grafana 13 image" 'executable file not found' \
  bash -c 'docker compose exec grafana grafana-cli --version 2>&1; true'
check "grafana cli is" docker compose exec grafana grafana cli --version
echo 'GRAFANA_ADMIN_PASSWORD=a-new-long-password' >.env

section "Import a dashboard"
if curl -fsS -o /dev/null https://grafana.com/api/dashboards/1860; then
  check_output "download and import 1860 (from the note)" '^/d/[A-Za-z0-9_-]+/node-exporter-full$' run "Import a dashboard"
  check_output "1860 selects the data source with the variable ds_prometheus" '^ds_prometheus datasource prometheus$' \
    jq -r '.templating.list[] | select(.type=="datasource") | "\(.name) \(.type) \(.query)"' node-exporter-full.json
  check_output "its panels use \${ds_prometheus}" '\$\{ds_prometheus\}' grep -m1 -o '[$]{ds_prometheus}' node-exporter-full.json
  check_output "the dashboard is in the search" 'Node Exporter Full' \
    curl -fsS -u "admin:a-new-long-password" "$G/api/search?query=Node%20Exporter%20Full"
else
  skip "download and import 1860" "grafana.com is not reachable from here"
fi

# An old-style dashboard with a placeholder, imported with the note's inputs.
cat >old-dashboard.json <<'EOF'
{
  "__inputs": [{"name": "DS_PROMETHEUS", "label": "Prometheus", "type": "datasource", "pluginId": "prometheus", "pluginName": "Prometheus"}],
  "uid": "old-style", "title": "Old style",
  "panels": [{"id": 1, "type": "timeseries", "title": "up", "datasource": {"type": "prometheus", "uid": "${DS_PROMETHEUS}"},
    "targets": [{"refId": "A", "expr": "up", "datasource": {"type": "prometheus", "uid": "${DS_PROMETHEUS}"}}]}]
}
EOF
check_output "a dashboard with __inputs, imported with inputs (from the note)" '^/d/old-style/old-style$' \
  bash -ec "GRAFANA_ADMIN_PASSWORD=a-new-long-password; $(note_block "$NOTE" "Import a dashboard" 2)"
check_output "the placeholder is replaced by the uid of the data source" '^"prometheus"$' \
  bash -c "curl -fsS -u admin:a-new-long-password $G/api/dashboards/uid/old-style | jq '.dashboard.panels[0].datasource.uid'"

section "A first panel"
expr=$(note_block "$NOTE" "A first panel" 1)
body=$(jq -n --arg e "$expr" '{from: "now-5m", to: "now",
  queries: [{refId: "A", datasource: {uid: "prometheus"}, expr: $e, intervalMs: 15000, maxDataPoints: 100}]}')
retry 60 bash -c "curl -fsS -u admin:a-new-long-password -H 'Content-Type: application/json' $G/api/ds/query -d '$body' | jq -e '.results.A.frames[0].data.values[1] | length > 0'" || true
check_output "the panel query with \$__rate_interval returns data" '"instance"' \
  bash -c "curl -fsS -u admin:a-new-long-password -H 'Content-Type: application/json' $G/api/ds/query -d '$body' | jq -c '.results.A.frames[0].schema.fields[1].labels'"
