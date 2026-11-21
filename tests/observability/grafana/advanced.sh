#!/usr/bin/env bash
# note: observability/grafana/advanced.md
# env: compose
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"

NOTE=observability/grafana/advanced
QS=observability/grafana/quickstart
G=http://localhost:3000
run() { bash -ec "$(note_block "$NOTE" "$1" "${2:-1}")"; }

# The lab of the quickstart note.
note_block "$QS" "Run it with Docker Compose" 2 >compose.yaml
note_block "$QS" "Run it with Docker Compose" 3 >.env
note_block observability/prometheus/quickstart "Run it with Docker Compose" 2 >prometheus.yml
mkdir -p grafana/provisioning/datasources grafana/provisioning/dashboards grafana/provisioning/alerting grafana/dashboards
note_block "$QS" "Provision the Prometheus data source" 1 >grafana/provisioning/datasources/prometheus.yaml
# shellcheck source=/dev/null
source .env
# The note's later blocks use the variable of the "source .env" of earlier blocks.
export GRAFANA_ADMIN_PASSWORD
api() { curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" "$@"; }
json() { curl -sS -u "admin:$GRAFANA_ADMIN_PASSWORD" -H 'Content-Type: application/json' "$@"; }
export -f api json
wait_grafana() { wait_http "$G/api/health" 120 || compose_logs grafana; }

section "Provision dashboards from files"
python3 - compose.yaml "$(note_block "$NOTE" "Provision dashboards from files" 1)" <<'EOF'
import sys
path, new = sys.argv[1], sys.argv[2]
old = """    volumes:
      - grafana-data:/var/lib/grafana
      - ./grafana/provisioning/datasources:/etc/grafana/provisioning/datasources:ro
"""
s = open(path).read()
assert old in s
open(path, "w").write(s.replace(old, new.rstrip("\n") + "\n", 1))
EOF
note_block "$NOTE" "Provision dashboards from files" 2 >grafana/provisioning/dashboards/infrastructure.yaml
note_block "$NOTE" "Provision dashboards from files" 3 >grafana/dashboards/node-overview.json
check "the dashboard is valid JSON" jq -e .uid grafana/dashboards/node-overview.json
docker compose up -d --quiet-pull 2>/dev/null
wait_grafana
retry 30 api "$G/api/dashboards/uid/node-overview" || true
meta=$(api "$G/api/dashboards/uid/node-overview" | jq -c '.meta | {provisioned, folderUid, folderTitle}')
assert_eq "provisioned, in the folder Infrastructure" '{"provisioned":true,"folderUid":"infrastructure","folderTitle":"Infrastructure"}' "$meta"
check_output "allowUiUpdates: false, saving from the API (as the UI does) is refused" 'provisioned dashboard' \
  bash -c "curl -sS -u admin:$GRAFANA_ADMIN_PASSWORD -H 'Content-Type: application/json' -X POST $G/api/dashboards/db \
    -d \"\$(api $G/api/dashboards/uid/node-overview | jq '{dashboard: .dashboard, folderUid: .meta.folderUid, overwrite: true}')\""
retry 60 bash -c "curl -fsS $G/api/health >/dev/null && curl -fsS -u admin:$GRAFANA_ADMIN_PASSWORD $G/api/datasources/uid/prometheus/resources/api/v1/query --data-urlencode 'query=up{job=\"node\"}' | grep -q node-exporter" || true
i=0
while IFS= read -r expr; do
  i=$((i + 1))
  e=${expr//\$instance/.*}
  body=$(jq -n --arg e "$e" '{from: "now-5m", to: "now", queries: [{refId: "A", datasource: {uid: "prometheus"}, expr: $e, intervalMs: 15000}]}')
  retry 45 bash -c "curl -fsS -u admin:$GRAFANA_ADMIN_PASSWORD -H 'Content-Type: application/json' $G/api/ds/query -d '$body' | jq -e '.results.A.frames[0].data.values[1] | length > 0'" || true
  check_output "panel $i query returns data" '"node-exporter:9100"' \
    bash -c "curl -fsS -u admin:$GRAFANA_ADMIN_PASSWORD -H 'Content-Type: application/json' $G/api/ds/query -d '$body' | jq -c '.results.A.frames[0].schema.fields[1].labels'"
done < <(jq -r '.panels[].targets[].expr' grafana/dashboards/node-overview.json)
assert_eq "two panels" 2 "$i"
jq '.title = "Node overview v2"' grafana/dashboards/node-overview.json >tmp.json && cat tmp.json >grafana/dashboards/node-overview.json
retry 75 bash -c "curl -fsS -u admin:$GRAFANA_ADMIN_PASSWORD $G/api/dashboards/uid/node-overview | jq -e '.dashboard.title == \"Node overview v2\"'" || true
check_output "a changed file is read again within updateIntervalSeconds" '^"Node overview v2"$' \
  bash -c "api() { curl -fsS -u admin:$GRAFANA_ADMIN_PASSWORD \"\$@\"; }; api $G/api/dashboards/uid/node-overview | jq .dashboard.title"
mv grafana/dashboards/node-overview.json node-overview.json.away
retry 75 bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -u admin:$GRAFANA_ADMIN_PASSWORD $G/api/dashboards/uid/node-overview)\" = 404 ]" || true
check_output "disableDeletion: false, deleting the file deletes the dashboard" '^404$' \
  curl -s -o /dev/null -w '%{http_code}' -u "admin:$GRAFANA_ADMIN_PASSWORD" "$G/api/dashboards/uid/node-overview"
note_block "$NOTE" "Provision dashboards from files" 3 >grafana/dashboards/node-overview.json
retry 75 api "$G/api/dashboards/uid/node-overview" || true

section "Variables and templating"
check_output "the variable query values (from the note)" '"node-exporter:9100"' run "Variables and templating"
check_output "the dashboard uses =~ with the variable" 'instance=~\\"\$instance\\"' cat grafana/dashboards/node-overview.json

section "The HTTP API and service accounts"
api_blocks=$(note_block "$NOTE" "The HTTP API and service accounts" 1; note_block "$NOTE" "The HTTP API and service accounts" 2)
out=$(bash -ec "$api_blocks")
assert_match "the token starts with glsa_ (from the note)" '^glsa_' "$(sed -n 1p <<<"$out")"
assert_match "search lists the dashboard with its folder" $'^node-overview\tNode overview\tInfrastructure$' "$out"
assert_match "the Editor token creates the folder" '^/dashboards/f/team-a' "$out"
assert_match "the query returns frames" '^[1-9][0-9]*$' "$(tail -1 <<<"$out")"
check_output "the folder exists" '"title":"Team A"' api "$G/api/folders/team-a"
check_output "a second run: service account already exists" 'service account already exists' \
  bash -c "curl -sS -u admin:$GRAFANA_ADMIN_PASSWORD -H 'Content-Type: application/json' -X POST $G/api/serviceaccounts -d '{\"name\": \"automation\", \"role\": \"Editor\"}'"
assert_eq "so the block gives a null token" null "$(bash -ec "$(note_block "$NOTE" "The HTTP API and service accounts" 1)")"
vid=$(json -X POST "$G/api/serviceaccounts" -d '{"name": "reader", "role": "Viewer"}' | jq .id)
vtok=$(json -X POST "$G/api/serviceaccounts/$vid/tokens" -d '{"name": "reader-token"}' | jq -r .key)
check_output "a Viewer token can read" 'node-overview' curl -fsS -H "Authorization: Bearer $vtok" "$G/api/search?type=dash-db"
check_output "but cannot create a folder: 403 Access denied" '^403 .*Access denied' \
  bash -c "curl -s -o /dev/stderr -w '%{http_code} ' -H 'Authorization: Bearer $vtok' -H 'Content-Type: application/json' -X POST $G/api/folders -d '{\"title\": \"X\"}' 2>&1 | tr -d '\n' | sed -E 's/^(.*)([0-9]{3}) $/\2 \1/'"
check_output "the /apis endpoint lists the dashboards" '"node-overview"' \
  bash -c "curl -fsS -u admin:$GRAFANA_ADMIN_PASSWORD $G/apis/dashboard.grafana.app/v1/namespaces/default/dashboards | jq -c '[.items[].metadata.name]'"

section "Alerting in Grafana"
note_block "$NOTE" "Alerting in Grafana" 1 >grafana/provisioning/alerting/node.yaml
docker compose restart grafana 2>/dev/null
wait_grafana
out=$(run "Alerting in Grafana" 2)
assert_match "the rule is provisioned from the file (from the note)" $'^node-down\tNodeDown\tfile$' "$out"
retry 90 bash -c "curl -fsS -u admin:$GRAFANA_ADMIN_PASSWORD $G/api/prometheus/grafana/api/v1/rules | jq -e '.data.groups[].rules[] | select(.name==\"NodeDown\" and .health==\"ok\")'" || true
assert_match "it is evaluated, inactive while the node is up" $'^NodeDown\tinactive\tok$' "$(run "Alerting in Grafana" 2)"
check_output "the folder Alerts was created" '"Alerts"' bash -c "curl -fsS -u admin:$GRAFANA_ADMIN_PASSWORD '$G/api/folders' | jq -c '[.[].title]'"
check_output "the contact point is provisioned" '"ops-webhook"' \
  bash -c "curl -fsS -u admin:$GRAFANA_ADMIN_PASSWORD $G/api/v1/provisioning/contact-points | jq -c '[.[].name]'"
check_output "the policy tree has ops-webhook as root receiver" '^"ops-webhook"$' \
  bash -c "curl -fsS -u admin:$GRAFANA_ADMIN_PASSWORD $G/api/v1/provisioning/policies | jq .receiver"
check_output "a provisioned rule cannot be changed from the API" 'provenance|[Pp]rovisioned' \
  bash -c "curl -sS -u admin:$GRAFANA_ADMIN_PASSWORD $G/api/v1/provisioning/alert-rules/node-down | jq '.title = \"x\"' | curl -sS -u admin:$GRAFANA_ADMIN_PASSWORD -H 'Content-Type: application/json' -X PUT $G/api/v1/provisioning/alert-rules/node-down -d @-"
docker compose stop node-exporter 2>/dev/null
retry 150 bash -c "curl -fsS -u admin:$GRAFANA_ADMIN_PASSWORD $G/api/prometheus/grafana/api/v1/rules | jq -e '.data.groups[].rules[] | select(.name==\"NodeDown\" and (.state==\"pending\" or .state==\"firing\"))'" || true
check_output "with node_exporter down, NodeDown becomes pending" $'NodeDown\t(pending|firing)' run "Alerting in Grafana" 2
docker compose start node-exporter 2>/dev/null

section "Plugins"
if curl -fsS -o /dev/null https://grafana.com/api/plugins/grafana-clock-panel; then
  check_output "grafana cli plugins install, restart, ls (from the note)" 'grafana-clock-panel' \
    bash -ec "$(note_block "$NOTE" "## Plugins" 2 | sed 's/^docker compose restart grafana$/& \&\& sleep 5/')"
  wait_grafana
  check_output "Grafana loaded it" '"id":"grafana-clock-panel"' api "$G/api/plugins/grafana-clock-panel/settings"
  check "the plugin is in /var/lib/grafana/plugins" docker compose exec grafana test -d /var/lib/grafana/plugins/grafana-clock-panel
  docker compose exec grafana grafana cli plugins uninstall grafana-clock-panel >/dev/null
  docker compose restart grafana 2>/dev/null
  wait_grafana
  check_fails "after uninstall it is gone" api "$G/api/plugins/grafana-clock-panel/settings"
  printf 'services:\n  grafana:\n%s\n' "$(note_block "$NOTE" "## Plugins" 1)" >plugins.yaml
  docker compose -f compose.yaml -f plugins.yaml up -d grafana 2>/dev/null
  wait_grafana
  check_output "GF_PLUGINS_PREINSTALL_SYNC installs it before the start (from the note)" '"id":"grafana-clock-panel"' \
    api "$G/api/plugins/grafana-clock-panel/settings"
else
  skip "plugin installation" "grafana.com is not reachable from here"
fi
check_output "GF_INSTALL_PLUGINS prints a deprecation warning" 'GF_INSTALL_PLUGINS is deprecated' \
  bash -c 'docker compose run --rm --no-deps -e GF_INSTALL_PLUGINS=grafana-clock-panel grafana --version 2>&1'

section "External database: PostgreSQL or MySQL"
note_block "$NOTE" "External database" 1 >compose.override.yaml
check "the override merges with compose.yaml" docker compose config -q
check "create the password file and start (from the note)" bash -ec "$(note_block "$NOTE" "External database" 2) 2>/dev/null"
wait_grafana
check_output "Grafana reports its database ok" '"database": "ok"' curl -fsS "$G/api/health"
check_output "Grafana created its tables in PostgreSQL" '\bdashboard\b' \
  docker compose exec postgres psql -U grafana -d grafana -Atc '\dt'
check_output "the provisioned dashboard is there again" '"provisioned":true' bash -c "curl -fsS -u admin:$GRAFANA_ADMIN_PASSWORD $G/api/dashboards/uid/node-overview | jq -c .meta"
check_output "but the SQLite data is not copied: no service account" '"totalCount":0' \
  api "$G/api/serviceaccounts/search"
check_output "the folder made with the API is not there either" '^404$' \
  curl -s -o /dev/null -w '%{http_code}' -u "admin:$GRAFANA_ADMIN_PASSWORD" "$G/api/folders/team-a"

section "grafana.ini and GF_ variables"
settings=$(api "$G/api/admin/settings")
check_output "GF_DATABASE_TYPE becomes [database] type" '^postgres$' jq -r .database.type <<<"$settings"
check_output "GF_DATABASE_HOST becomes [database] host" '^postgres:5432$' jq -r .database.host <<<"$settings"
check_output "the __FILE password is not shown" '^\*+$' jq -r .database.password <<<"$settings"
