#!/usr/bin/env bash
# note: observability/prometheus/quickstart.md
# env: compose
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=observability/prometheus/quickstart
P=http://localhost:9090

# query EXPR: the result of an instant query, one "job value" line per series.
query() {
  curl -fsS "$P/api/v1/query" --data-urlencode "query=$1" |
    jq -r '.data.result[] | "\(.metric.job // "-") \(.value[1])"'
}

section "Run it with Docker Compose"
note_block "$NOTE" "Run it with Docker Compose" 1 >compose.yaml
note_block "$NOTE" "Run it with Docker Compose" 2 >prometheus.yml
check_output "the note pins the versions of versions.env" "prom/prometheus:$PROMETHEUS_VERSION" cat compose.yaml
check_output "node-exporter image too" "prom/node-exporter:$NODE_EXPORTER_VERSION" cat compose.yaml
check "docker compose accepts the file" docker compose config -q

section "Check the configuration"
check_output "promtool check config (from the note)" 'SUCCESS: /prometheus.yml is valid prometheus config file syntax' \
  bash -ec "$(note_block "$NOTE" "Check the configuration")"
printf 'global:\n  scrape_interval: 15\nscrape_configs: [\n' >broken.yml
check_fails "promtool fails on a broken file" \
  docker run --rm -v "$PWD/broken.yml:/prometheus.yml:ro" --entrypoint promtool \
  "prom/prometheus:$PROMETHEUS_VERSION" check config /prometheus.yml

section "Start the stack"
docker compose up -d --quiet-pull 2>/dev/null
wait_http "$P/-/ready" 90 || compose_logs prometheus
check_output "/-/ready answers as the note says (from the note)" '^Prometheus Server is Ready\.$' \
  bash -ec "$(note_block "$NOTE" "Start the stack")"
check_output "node_exporter answers on 9100" '^node_cpu_seconds_total' \
  bash -c "curl -fsS http://localhost:9100/metrics | grep -m1 '^node_cpu_seconds_total'"

section "The web UI and the targets API"
check "the UI answers" curl -fsS -o /dev/null "$P/query"
# Both targets are scraped within one interval (15 s).
retry 60 bash -c "[ \"\$(curl -fsS $P/api/v1/targets | jq '[.data.activeTargets[] | select(.health==\"up\")] | length')\" = 2 ]" || true
out=$(bash -ec "$(note_block "$NOTE" "The web UI and the targets API" 1)")
assert_match "node target is up (from the note)" $'^node\thttp://node-exporter:9100/metrics\tup' "$out"
assert_match "prometheus target is up" $'^prometheus\thttp://localhost:9090/metrics\tup' "$out"

section "First PromQL queries"
out=$(bash -ec "$(note_block "$NOTE" "First PromQL queries" 1)")
assert_match "up is 1 for node (from the note)" '^node 1$' "$out"
assert_match "up is 1 for prometheus" '^prometheus 1$' "$out"
# rate() needs two samples: wait for the third scrape.
retry 60 bash -c "curl -fsS $P/api/v1/query --data-urlencode 'query=rate(node_cpu_seconds_total[5m])' | jq -e '.data.result | length > 0'" || true
i=0
while IFS= read -r q; do
  [[ -z $q || $q == \#* ]] && continue
  i=$((i + 1))
  out=$(query "$q")
  assert_match "PromQL query $i returns a value: $q" '^- [0-9.e+-]+$|^[a-z]+ [0-9.e+-]+$' "$out"
done < <(note_block "$NOTE" "First PromQL queries" 2)
assert_eq "the note has the four queries" 4 "$i"
mem=$(query '100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)' | awk '{print $2}')
check "memory used is a percentage between 0 and 100" awk -v v="$mem" 'BEGIN { exit !(v > 0 && v < 100) }'
check_output "a counter only goes up: node_cpu_seconds_total is a counter" 'TYPE node_cpu_seconds_total counter' \
  curl -fsS http://localhost:9100/metrics
check_output "node_memory_MemAvailable_bytes is a gauge" 'TYPE node_memory_MemAvailable_bytes gauge' \
  curl -fsS http://localhost:9100/metrics
