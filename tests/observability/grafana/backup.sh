#!/usr/bin/env bash
# note: observability/grafana/backup.md
# env: compose
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=observability/grafana/backup
QS=observability/grafana/quickstart
ADV=observability/grafana/advanced
G=http://localhost:3000
run() { bash -ec "$(note_block "$NOTE" "$1" "${2:-1}")"; }
wait_grafana() { wait_http "$G/api/health" 120 || compose_logs grafana; }

# The lab of the quickstart, with the provisioned dashboard of the advanced note.
note_block "$QS" "Run it with Docker Compose" 2 >compose.yaml
note_block "$QS" "Run it with Docker Compose" 3 >.env
note_block observability/prometheus/quickstart "Run it with Docker Compose" 2 >prometheus.yml
mkdir -p grafana/provisioning/datasources grafana/provisioning/dashboards grafana/dashboards
note_block "$QS" "Provision the Prometheus data source" 1 >grafana/provisioning/datasources/prometheus.yaml
note_block "$ADV" "Provision dashboards from files" 2 >grafana/provisioning/dashboards/infrastructure.yaml
note_block "$ADV" "Provision dashboards from files" 3 >grafana/dashboards/node-overview.json
sed -i 's|      - ./grafana/provisioning/datasources:/etc/grafana/provisioning/datasources:ro|&\n      - ./grafana/provisioning/dashboards:/etc/grafana/provisioning/dashboards:ro\n      - ./grafana/dashboards:/etc/grafana/dashboards:ro|' compose.yaml
# shellcheck source=/dev/null
source .env
api() { curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" "$@"; }
post() { curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" -H 'Content-Type: application/json' -X POST "$@"; }
docker compose up -d --quiet-pull 2>/dev/null
wait_grafana
retry 30 api "$G/api/dashboards/uid/node-overview" || true

# Content made in the UI: a folder, a dashboard in it, a data source with a secret.
post "$G/api/folders" -d '{"uid": "ops", "title": "Ops"}' >/dev/null
post "$G/api/dashboards/db" -d '{"dashboard": {"uid": "disk", "title": "Disk", "panels": []}, "folderUid": "ops"}' >/dev/null
post "$G/api/datasources" -d '{"name": "Secret DS", "uid": "secret-ds", "type": "prometheus", "access": "proxy",
  "url": "http://prometheus:9090", "basicAuth": true, "basicAuthUser": "u", "secureJsonData": {"basicAuthPassword": "s3cret"}}' >/dev/null

section "What to back up"
check "grafana.db is in /var/lib/grafana" docker compose exec grafana test -f /var/lib/grafana/grafana.db
check "the plugins folder is in /var/lib/grafana" docker compose exec grafana test -d /var/lib/grafana/plugins

section "Copy the SQLite database"
check "stop, tar the data folder, start (from the note)" run "Copy the SQLite database" 1
check_output "the archive has grafana.db" '^\./grafana\.db$' tar -tzf backup/grafana-data.tar.gz
wait_grafana
check_output "sqlite3 .backup online, integrity ok (from the note)" '^ok$' run "Copy the SQLite database" 2
check "Grafana kept running" curl -fsS "$G/api/health"
assert_file "backup/grafana.db exists" backup/grafana.db
post "$G/api/dashboards/db" -d '{"dashboard": {"uid": "after", "title": "After backup", "panels": []}}' >/dev/null

section "Restore the database"
check "stop, copy back, chown, start (from the note)" run "Restore the database" 1
wait_grafana
out=$(run "Restore the database" 2)
assert_match "the database is ok (from the note)" '^ok$' "$out"
assert_match "the dashboard from before the backup is there" '^Disk$' "$out"
assert_no_match "the one made after the backup is gone" '^After backup$' "$out"
check_output "the file belongs to 472" '^472$' docker compose exec grafana stat -c %u /var/lib/grafana/grafana.db

# The secret key warning: the same backup, in a Grafana with another secret_key.
mkdir -p other
cp backup/grafana.db other/
chmod 666 other/grafana.db
cid=$(docker run -d --label "com.docker.compose.project=$COMPOSE_PROJECT_NAME" \
  --label com.docker.compose.service=other --label com.docker.compose.oneoff=False -e GF_SECURITY_SECRET_KEY=another-key \
  --network "${COMPOSE_PROJECT_NAME}_default" -v "$PWD/other:/backup:ro" --entrypoint sh "grafana/grafana:$GRAFANA_VERSION" \
  -c 'cp /backup/grafana.db /var/lib/grafana/grafana.db && exec /run.sh')
retry 90 docker exec "$cid" curl -fs http://localhost:3000/api/health >/dev/null || true
secret=$(docker exec "$cid" curl -s -u "admin:$GRAFANA_ADMIN_PASSWORD" http://localhost:3000/api/datasources/uid/secret-ds/health)
assert_no_match "with another secret_key, the data source secret cannot be used" '"status":"OK"' "$secret"
echo "# secret-ds health with another key: $secret"
docker rm -f "$cid" >/dev/null
check_output "with the right key, the same data source works" '"status":"OK"' api "$G/api/datasources/uid/secret-ds/health"

section "Export all dashboards with the API"
TOKEN=$(bash -ec "$(note_block "$ADV" "The HTTP API and service accounts" 1)" | head -1)
export TOKEN
assert_match "a service account token" '^glsa_' "$TOKEN"
out=$(run "Export all dashboards with the API")
while IFS= read -r l; do echo "# export: $l"; done <<<"$out"
assert_match "the export lists disk.json (from the note)" '^disk\.json$' "$out"
assert_no_match "the provisioned dashboard is left out" 'node-overview' "$out"
check_output "each file has the dashboard, its folder, overwrite" '^\{"id":null,"title":"Disk","folderUid":"ops","overwrite":true\}$' \
  jq -c '{id: .dashboard.id, title: .dashboard.title, folderUid, overwrite}' export/dashboards/disk.json
check_output "the folders are exported" '"uid":"ops","title":"Ops"' jq -c '.[]' export/folders.json

section "Re-import the dashboards"
curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" -X DELETE "$G/api/dashboards/uid/disk" >/dev/null
curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" -X DELETE "$G/api/folders/ops" >/dev/null
check_output "the dashboard is gone" '^404$' curl -s -o /dev/null -w '%{http_code}' -u "admin:$GRAFANA_ADMIN_PASSWORD" "$G/api/dashboards/uid/disk"
out=$(bash -ec "G=$G; AUTH='Authorization: Bearer $TOKEN'
$(note_block "$NOTE" "Re-import the dashboards")")
assert_match "each import prints success <uid> (from the note)" '^success disk$' "$out"
check_output "the dashboard is back, in its folder" '"folderUid":"ops"' \
  bash -c "curl -fsS -u admin:$GRAFANA_ADMIN_PASSWORD $G/api/dashboards/uid/disk | jq -c .meta"
out=$(bash -ec "G=$G; AUTH='Authorization: Bearer $TOKEN'
$(note_block "$NOTE" "Re-import the dashboards")")
assert_match "a second import replaces it: success again" '^success disk$' "$out"
