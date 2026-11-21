#!/usr/bin/env bash
# note: observability/grafana/troubleshooting.md
# env: compose
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=observability/grafana/troubleshooting
QS=observability/grafana/quickstart
ADV=observability/grafana/advanced
G=http://localhost:3000
run() { bash -ec "$(note_block "$NOTE" "$1" "${2:-1}")"; }
wait_grafana() { wait_http "$G/api/health" 120 || compose_logs grafana; }
# stopped: "<restarts> <status> <exit code>" of the grafana container. With a restart
# policy, `docker compose ps` shows Up between two restarts, so read the counters.
stopped() { docker inspect -f '{{.RestartCount}} {{.State.Status}} {{.State.ExitCode}}' "$(docker compose ps -aq grafana)"; }
export -f stopped
# service_override FILE HEADING N: a compose override that adds a block of the note to the grafana service.
service_override() { printf 'services:\n  grafana:\n%s\n' "$(note_block "$NOTE" "$2" "$3")" >"$1"; }

note_block "$QS" "Run it with Docker Compose" 2 >compose.yaml
note_block "$QS" "Run it with Docker Compose" 3 >.env
note_block observability/prometheus/quickstart "Run it with Docker Compose" 2 >prometheus.yml
mkdir -p grafana/provisioning/datasources
note_block "$QS" "Provision the Prometheus data source" 1 >grafana/provisioning/datasources/prometheus.yaml
# The mistake of the note: a data source that points to localhost.
sed -e 's/name: Prometheus/name: Prometheus on localhost/' -e 's/uid: prometheus/uid: prometheus-localhost/' \
  -e 's|http://prometheus:9090|http://localhost:9090|' -e 's/isDefault: true/isDefault: false/' \
  grafana/provisioning/datasources/prometheus.yaml >grafana/provisioning/datasources/localhost.yaml
# shellcheck source=/dev/null
source .env
export GRAFANA_ADMIN_PASSWORD
api() { curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" "$@"; }
docker compose up -d --quiet-pull 2>/dev/null
wait_grafana

section "Read the logs first"
check_output "docker compose logs (from the note): lines have level and logger" 'logger=[a-z.]+ .*level=info' run "Read the logs first" 1
check_output "the health endpoint needs no login (from the note)" '"database": "ok"' run "Read the logs first" 3
service_override debug.yaml "Read the logs first" 2
docker compose -f compose.yaml -f debug.yaml up -d grafana 2>/dev/null
wait_grafana
check_output "GF_LOG_LEVEL=debug gives debug lines" 'level=debug' bash -c "docker compose logs --tail 200 grafana 2>&1"
docker compose up -d grafana 2>/dev/null
wait_grafana

section "Data source errors"
out=$(run "Data source errors" 1)
assert_match "localhost in the container: status ERROR (from the note)" '"status":"ERROR"' "$out"
assert_match "connection refused" 'connect: connection refused' "$out"
assert_match "the note's example output says the same" 'connection refused.*"status":"ERROR"' "$(note_block "$NOTE" "Data source errors" 2)"
check_output "the service name works" '"status":"OK"' api "$G/api/datasources/uid/prometheus/health"
check_output "the query proxy answers 502 Bad Gateway" '^502$' \
  curl -s -o /dev/null -w '%{http_code}' -u "admin:$GRAFANA_ADMIN_PASSWORD" "$G/api/datasources/proxy/uid/prometheus-localhost/api/v1/query?query=up"
check_output "wget from the Grafana container (from the note)" 'Prometheus Server is Ready' run "Data source errors" 4
service_override hosts.yaml "Data source errors" 3
docker compose -f compose.yaml -f hosts.yaml up -d grafana 2>/dev/null
wait_grafana
check_output "extra_hosts adds host.docker.internal to /etc/hosts" 'host\.docker\.internal' \
  docker compose exec grafana grep host.docker.internal /etc/hosts
docker compose up -d grafana 2>/dev/null
wait_grafana
check_output "a provisioned data source is read-only" '[Rr]ead.only|provisioned' \
  bash -c "curl -sS -u admin:$GRAFANA_ADMIN_PASSWORD $G/api/datasources/uid/prometheus | jq '.url = \"http://x:9090\"' | curl -sS -u admin:$GRAFANA_ADMIN_PASSWORD -H 'Content-Type: application/json' -X PUT $G/api/datasources/uid/prometheus -d @-"

section "Panels show \"No data\""
dsq() {
  jq -n --arg e "$1" '{from: "now-5m", to: "now", queries: [{refId: "A", datasource: {uid: "prometheus"}, expr: $e, intervalMs: 15000}]}' |
    curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" -H 'Content-Type: application/json' "$G/api/ds/query" -d @- |
    jq '[.results.A.frames[]?.data.values[1]? // [] | length] | add // 0'
}
retry 60 bash -c "[ \"\$(curl -fsS -u admin:$GRAFANA_ADMIN_PASSWORD -G $G/api/datasources/uid/prometheus/resources/api/v1/query --data-urlencode 'query=rate(node_cpu_seconds_total[1m])' | jq '.data.result | length')\" -gt 0 ]" || true
check_output "up{job=\"node\"} has data" '^[1-9][0-9]*$' dsq 'up{job="node"}'
check_output "a wrong label: no data, no error" '^0$' dsq 'up{job="nodes"}'
check_output "rate() over one scrape interval: no data" '^0$' \
  bash -c "curl -fsS -G $G/api/datasources/uid/prometheus/resources/api/v1/query -u admin:$GRAFANA_ADMIN_PASSWORD --data-urlencode 'query=rate(node_cpu_seconds_total[15s])' | jq '.data.result | length'"
retry 60 bash -c "$(declare -f dsq); G=$G; GRAFANA_ADMIN_PASSWORD=$GRAFANA_ADMIN_PASSWORD; [ \"\$(dsq 'rate(node_cpu_seconds_total[\$__rate_interval])')\" -gt 0 ]" || true
check_output "rate() over \$__rate_interval: data" '^[1-9][0-9]*$' dsq 'rate(node_cpu_seconds_total[$__rate_interval])'

section "Login loops and wrong links behind a reverse proxy"
note_block "$NOTE" "Login loops" 2 >nginx.conf
printf 'services:\n%s\n' "$(note_block "$NOTE" "Login loops" 3)" >proxy.yaml
docker compose -f compose.yaml -f proxy.yaml up -d --quiet-pull nginx 2>/dev/null
retry 30 curl -s -o /dev/null http://localhost:8080/ || true
check_output "without root_url and serve_from_sub_path, /grafana/ fails" '^(404|30[12])$' \
  curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/grafana/api/health
service_override subpath.yaml "Login loops" 1
docker compose -f compose.yaml -f proxy.yaml -f subpath.yaml up -d grafana nginx 2>/dev/null
retry 120 curl -fsS -o /dev/null http://localhost:8080/grafana/api/health || true
check_output "with them, /grafana/api/health answers through nginx" '"database": "ok"' curl -fsS http://localhost:8080/grafana/api/health
check_output "/grafana/ redirects to /grafana/login" '^[Ll]ocation: /grafana/login' \
  bash -c "curl -sI http://localhost:8080/grafana/ | tr -d '\r'"
check_output "the login page sets <base href=\"/grafana/\">" '<base href="/grafana/"' curl -fsS http://localhost:8080/grafana/login
css=$(curl -fsS http://localhost:8080/grafana/login | grep -o -m1 'public/build/[^"]*\.css' || true)
check "so its assets load through the proxy: /grafana/$css" curl -fsS -o /dev/null "http://localhost:8080/grafana/$css"
check_output "a login through the proxy sets the session cookie" '[Ss]et-[Cc]ookie: grafana_session=' \
  bash -c "curl -s -D - -o /dev/null -H 'Content-Type: application/json' -X POST http://localhost:8080/grafana/login -d '{\"user\":\"admin\",\"password\":\"$GRAFANA_ADMIN_PASSWORD\"}' | tr -d '\r'"
check_output "the WebSocket of Grafana Live is upgraded" '^HTTP/1.1 101' \
  bash -c "curl -s -i -N --max-time 3 -u admin:$GRAFANA_ADMIN_PASSWORD -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' http://localhost:8080/grafana/api/live/ws | head -1; true"
docker compose -f compose.yaml -f proxy.yaml stop nginx 2>/dev/null
docker compose up -d grafana 2>/dev/null
wait_grafana

section "Permission errors on /var/lib/grafana"
docker compose stop grafana 2>/dev/null
# First case: grafana.db exists, the folder is not writable.
docker compose run --rm --no-deps --user root --entrypoint sh grafana -c 'chown root:root /var/lib/grafana && chmod 755 /var/lib/grafana' 2>/dev/null
docker compose up -d grafana 2>/dev/null
retry 240 bash -c "stopped | grep -q -E '^[1-9]|exited'" || true
check_output "with grafana.db, Grafana stops (exit 1), and restart: unless-stopped starts it again" '^[1-9][0-9]* |exited 1$' stopped
check_output "with the note's first line" "$(note_block "$NOTE" "Permission errors" 1 | head -1 | sed 's/[.]/\\./g')" \
  bash -c "docker compose logs grafana 2>&1"
check_output "and attempt to write a readonly database" 'attempt to write a readonly database' bash -c "docker compose logs grafana 2>&1"
# Second case: an empty folder owned by root, as a new bind mount. The container is not
# recreated: Docker would fill an empty named volume from the image, with its owner.
docker compose stop grafana 2>/dev/null
docker compose run --rm --no-deps --user root --entrypoint sh grafana -c 'rm -rf /var/lib/grafana/* && chown root:root /var/lib/grafana && chmod 755 /var/lib/grafana' 2>/dev/null
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
docker compose up -d grafana 2>/dev/null
retry 60 bash -c "docker compose logs --since $since grafana 2>&1 | grep -q 'Permission denied'" || true
logs=$(docker compose logs --no-log-prefix --since "$since" grafana 2>&1)
while IFS= read -r line; do
  # shellcheck disable=SC2001  # a bracket expression, not a plain substitution
  assert_match "an empty folder owned by root: the note's line '${line:0:40}...'" "$(sed 's/[][().*]/\\&/g' <<<"$line")" "$logs"
done < <(note_block "$NOTE" "Permission errors" 1)
# The note's chown on the host, run on the volume.
fix=$(note_block "$NOTE" "Permission errors" 2)
assert_match "the note's fix is chown -R 472:0" 'chown -R 472:0' "$fix"
docker compose run --rm --no-deps --user root --entrypoint sh grafana -c 'chown -R 472:0 /var/lib/grafana' 2>/dev/null
docker compose up -d grafana 2>/dev/null
wait_grafana
check "after chown -R 472:0 it starts" curl -fsS "$G/api/health"

section "\"database is locked\""
service_override wal.yaml "database is locked" 1
docker compose -f compose.yaml -f wal.yaml up -d grafana 2>/dev/null
wait_grafana
api "$G/api/search" >/dev/null
check "GF_DATABASE_WAL=true: SQLite runs in WAL mode (grafana.db-wal)" docker compose exec grafana test -f /var/lib/grafana/grafana.db-wal

section "Provisioning errors"
mkdir -p grafana/provisioning/dashboards grafana/dashboards
note_block "$ADV" "Provision dashboards from files" 2 >grafana/provisioning/dashboards/infrastructure.yaml
echo '{"uid": "broken", "title": "Broken",' >grafana/dashboards/broken.json
cat >dash.yaml <<'EOF'
services:
  grafana:
    volumes:
      - ./grafana/provisioning/dashboards:/etc/grafana/provisioning/dashboards:ro
      - ./grafana/dashboards:/etc/grafana/dashboards:ro
EOF
docker compose -f compose.yaml -f dash.yaml up -d grafana 2>/dev/null
wait_grafana
retry 30 bash -c "docker compose logs grafana 2>&1 | grep -q 'logger=provisioning.dashboard.*level=error'" || true
check "a broken dashboard file: Grafana still starts" curl -fsS "$G/api/health"
check_output "the grep of the note finds the error" 'logger=provisioning.dashboard.*level=error' run "Provisioning errors" 1
check_fails "jq empty fails on the broken file (from the note)" run "Provisioning errors" 2
check_output "and prints where" 'line [0-9]+' bash -c "$(note_block "$NOTE" "Provisioning errors" 2) 2>&1; true"
note_block "$ADV" "Provision dashboards from files" 3 >grafana/dashboards/broken.json
check_output "jq empty prints nothing for good files" '^$' run "Provisioning errors" 2
printf 'apiVersion: 1\ndatasources:\n  - name: [broken\n' >grafana/provisioning/datasources/broken.yaml
docker compose up -d --force-recreate grafana 2>/dev/null
# Grafana takes a minute or two to give up on a loaded machine.
retry 300 bash -c "stopped | grep -q -E '^[1-9]|exited'" || true
check_output "a broken data source file stops Grafana (exit 1)" '^[1-9][0-9]* |exited 1$' stopped
check_output "with 'Datasource provisioning error' in the logs" 'Datasource provisioning error' \
  bash -c "docker compose logs --no-log-prefix grafana 2>&1"
