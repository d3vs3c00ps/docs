#!/usr/bin/env bash
# note: observability/prometheus/troubleshooting.md
# env: compose
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=observability/prometheus/troubleshooting
ADV=observability/prometheus/advanced
P=http://localhost:9090
A=http://localhost:9093
q() { curl -fsS "$P/api/v1/query" --data-urlencode "query=$1" | jq -c .data.result; }
has() { [[ $(q "$1") != "[]" ]]; }
run() { bash -ec "$(note_block "$NOTE" "$1" "${2:-1}")"; }
reload() { curl -fsS -X POST "$P/-/reload"; }
# eventually DESC REGEX EXPR: the query result matches REGEX within 90 s.
eventually() {
  retry 90 bash -c "curl -fsS '$P/api/v1/query' --data-urlencode 'query=$3' | jq -c .data.result | grep -Eq -- '$2'" || true
  check_output "$1" "$2" q "$3"
}

# The lab of the advanced note.
mkdir -p prometheus/rules prometheus/targets alertmanager
note_block "$ADV" "The lab" 2 >compose.yaml
note_block "$ADV" "The lab" 3 >prometheus/prometheus.yml
note_block "$ADV" "### file_sd" 1 >prometheus/targets/node.yml
note_block "$ADV" "Recording and alerting rules" 1 >prometheus/rules/node.yml
note_block "$ADV" "## Alertmanager" 1 >alertmanager/alertmanager.yml
cp prometheus/prometheus.yml lab.yml

section "A target is down"
note_block "$NOTE" "A target is down" 2 >>prometheus/prometheus.yml
docker compose up -d --quiet-pull 2>/dev/null
wait_http "$P/-/ready" 90 || compose_logs prometheus
retry 90 bash -c "[ \"\$(curl -fsS $P/api/v1/targets | jq -c '[.data.activeTargets[] | .health] | group_by(.) | map({(.[0]): length}) | add')\" = '{\"down\":4,\"up\":3}' ]" || true
out=$(run "A target is down" 1)
table=$(sed -n '/^| `lastError` contains/,/^$/p' "$NOTES_ROOT/content/$NOTE.md")
for row in "wrong-port connect: connection refused" "wrong-name no such host" \
  "wrong-scheme server gave HTTP response to HTTPS client" "too-slow context deadline exceeded"; do
  job=${row%% *} err=${row#* }
  assert_match "$job is down with '$err' (from the note)" "^$job	.*$err" "$out"
  assert_match "the table lists '$err'" "$err" "$table"
done
assert_no_match "the node target is up" '^node	' "$out"
check_output "wget from the Prometheus container (from the note)" '^# HELP' run "A target is down" 3

section "Configuration errors and failed reloads"
check_output "promtool check config in the container (from the note)" 'SUCCESS' run "Configuration errors and failed reloads" 1
note_block "$NOTE" "A target is down" 2 | head -3 >>prometheus/prometheus.yml
check_output "a duplicate job_name: promtool names it" 'wrong-port' bash -c "$(note_block "$NOTE" "Configuration errors and failed reloads" 1) 2>&1; true"
check_fails "and fails" run "Configuration errors and failed reloads" 1
check_fails "the reload fails" reload
check_output "the failed reload shows in the metric (from the note)" '"0"\]' \
  bash -c "sleep 20; curl -fsS $P/api/v1/query --data-urlencode 'query=$(note_block "$NOTE" "Configuration errors and failed reloads" 2)' | jq -c .data.result"
check_output "the log has the reason (from the note)" 'Error reloading config' run "Configuration errors and failed reloads" 3
check "Prometheus still runs" curl -fsS "$P/-/ready"
docker compose restart prometheus >/dev/null 2>&1 || true
retry 20 bash -c "docker compose ps -a prometheus | grep -q 'Exited'" || true
check_output "at start, a bad file stops Prometheus: Exited (2)" 'Exited \(2\)' docker compose ps -a prometheus
check_output "the last log line has the error" 'wrong-port' bash -c "docker compose logs prometheus 2>&1 | tail -3"
cp lab.yml prometheus/prometheus.yml
note_block "$NOTE" "A target is down" 2 >>prometheus/prometheus.yml
docker compose up -d prometheus 2>/dev/null
retry 60 curl -fsS "$P/-/ready" || true

section "High cardinality"
check_output "the TSDB status API (from the note)" '^[0-9]+ [a-z_:]+$' run "High cardinality" 1
check_output "topk by __name__ (from the note)" '"__name__"' q "$(note_block "$NOTE" "High cardinality" 2)"
check_output "the label query is valid PromQL" '"status":"success"' \
  curl -fsS "$P/api/v1/query" --data-urlencode "query=$(note_block "$NOTE" "High cardinality" 3)"
note_block "$NOTE" "High cardinality" 4 | sed 's/job_name: node$/job_name: node-limited/' >>prometheus/prometheus.yml
reload
retry 60 bash -c "curl -fsS $P/api/v1/targets | jq -e '.data.activeTargets[] | select(.labels.job==\"node-limited\" and .health==\"down\")'" || true
check_output "sample_limit: the target is down with 'sample limit exceeded'" 'sample limit exceeded' \
  bash -c "curl -fsS $P/api/v1/targets | jq -r '.data.activeTargets[] | select(.labels.job==\"node-limited\") | .lastError'"
assert_eq "nothing from it is stored" "[]" "$(q 'node_cpu_seconds_total{job="node-limited"}')"
check "prometheus_tsdb_head_series exists" has prometheus_tsdb_head_series

section "Slow start and WAL replay"
docker compose restart prometheus >/dev/null 2>&1
seen503=0
for _ in $(seq 100); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$P/-/ready" || true)
  [[ $code == 503 ]] && { seen503=1; healthy=$(curl -s -o /dev/null -w '%{http_code}' "$P/-/healthy" || true); break; }
  [[ $code == 200 ]] && break
  sleep 0.1
done
if ((seen503)); then
  assert_eq "while it replays, /-/ready is 503" 1 "$seen503"
  assert_eq "and /-/healthy is 200" 200 "$healthy"
else
  skip "/-/ready is 503 during the replay" "the lab WAL replays faster than the test can poll"
fi
retry 60 curl -fsS "$P/-/ready" || true
logs=$(compose_logs prometheus)
assert_match "the log says Replaying WAL" 'Replaying WAL, this may take a while' "$logs"
assert_match "then WAL replay completed" 'WAL replay completed' "$logs"
# Corrupt the end of the last WAL segment, as a power loss would.
docker compose stop prometheus >/dev/null 2>&1
docker compose run --rm --no-deps --entrypoint sh prometheus -c \
  'seg=$(ls /prometheus/wal | grep -E "^[0-9]+$" | tail -1); head -c 3000 /dev/urandom >>"/prometheus/wal/$seg"' >/dev/null 2>&1
docker compose start prometheus >/dev/null 2>&1
retry 90 curl -fsS "$P/-/ready" || true
check "after a corrupted WAL, Prometheus repairs it and starts" curl -fsS "$P/-/ready"
check_output "and logs the repair" '[Rr]epair' bash -c "docker compose logs prometheus 2>&1 | grep -i -E 'corrupt|repair'"

section "Out-of-order samples"
mkdir -p sd
cat >sd.yaml <<'EOF'
services:
  sd:
    image: prom/prometheus:${PROMETHEUS_VERSION}
    entrypoint: ["httpd", "-f", "-p", "8000", "-h", "/www"]
    volumes:
      - ./sd:/www:ro
EOF
# An exporter that sets its own timestamps (in ms), the second one older than the first.
now=$(($(date +%s) * 1000))
printf 'demo_value 1 %s\n' "$now" >sd/metrics
PROMETHEUS_VERSION=$PROMETHEUS_VERSION docker compose -f compose.yaml -f sd.yaml up -d sd 2>/dev/null
printf '  - job_name: own-timestamps\n    static_configs:\n      - targets: ["sd:8000"]\n' >>prometheus/prometheus.yml
reload
retry 45 bash -c "curl -fsS $P/api/v1/targets | jq -e '.data.activeTargets[] | select(.labels.job==\"own-timestamps\" and .health==\"down\")'" || true
err=$(curl -fsS "$P/api/v1/targets" | jq -r '.data.activeTargets[] | select(.labels.job=="own-timestamps") | .lastError')
assert_match "busybox httpd sends no text/plain: the scrape fails on the Content-Type" 'unsupported Content-Type|blank Content-Type' "$err"
table=$(sed -n '/^| `lastError` contains/,/^$/p' "$NOTES_ROOT/content/$NOTE.md")
assert_match "the table has this error" "$(grep -oE 'unsupported Content-Type|blank Content-Type' <<<"$err" | head -1)" "$table"
sed -i 's/  - job_name: own-timestamps/&\n    fallback_scrape_protocol: PrometheusText0.0.4/' prometheus/prometheus.yml
reload
retry 40 has 'demo_value' || true
printf 'demo_value 2 %s\n' "$((now - 120000))" >sd/metrics
check_output "an older sample is dropped and counted (from the note)" '"[1-9][0-9.]*"\]' \
  bash -c "sleep 35; curl -fsS $P/api/v1/query --data-urlencode 'query=prometheus_target_scrapes_sample_out_of_order_total' | jq -c '[.data.result[] | select(.value[1] != \"0\")]'"
check "the note's alert query is valid" curl -fsS "$P/api/v1/query" --data-urlencode "query=$(note_block "$NOTE" "Out-of-order samples" 1)"
python3 - prometheus/prometheus.yml "$(note_block "$NOTE" "Out-of-order samples" 2)" <<'PYEOF'
import sys
path, block = sys.argv[1], sys.argv[2]
s = open(path).read()
assert "storage:\n  tsdb:\n" in s
s = s.replace("storage:\n  tsdb:\n", "storage:\n  tsdb:\n    out_of_order_time_window: 30m\n", 1)
assert "out_of_order_time_window: 30m" in block
open(path, "w").write(s)
PYEOF
check "out_of_order_time_window applies on reload" reload
printf 'demo_value 3 %s\n' "$((now - 60000))" >sd/metrics
eventually "with the window, the late sample is accepted" '"[1-9][0-9.]*"\]' \
  'sum(prometheus_tsdb_head_out_of_order_samples_appended_total)'

section "Disk full"
skip "no space left on device" "filling a disk is not done in a shared test machine"
check "prometheus_tsdb_compactions_failed_total exists" has prometheus_tsdb_compactions_failed_total
check_output "the predict_linear alert is valid PromQL" '"status":"success"' \
  curl -fsS "$P/api/v1/query" --data-urlencode "query=$(note_block "$NOTE" "Disk full" 1)"

section "Time skew"
check_output "the skew query is valid (from the note)" '"status":"success"' \
  curl -fsS "$P/api/v1/query" --data-urlencode "query=$(note_block "$NOTE" "Time skew" 1)"
assert_eq "it is empty: the clocks are in sync" "[]" "$(q "$(note_block "$NOTE" "Time skew" 1)")"
check_output "node_time_seconds and its timestamp are close" '"0(\.[0-9]+)?"' \
  q 'round(abs(timestamp(node_time_seconds) - node_time_seconds))'

section "Query from the command line"
out=$(run "Query from the command line")
assert_match "promtool query instant lists the down targets (from the note)" 'up\{.*job="wrong-port".*\} => 0 @\[' "$out"
assert_match "the output looks like the note says" '^\{job="node"\} => 1 @\[[0-9.]+\]$' "$out"

section "Alerts do not reach Alertmanager"
check_output "1. Watchdog fires in Prometheus (from the note)" $'^Watchdog\tfiring$' run "Alerts do not reach Alertmanager" 1
while IFS= read -r expr; do
  check_output "2. $expr is valid" '"status":"success"' curl -fsS "$P/api/v1/query" --data-urlencode "query=$expr"
done < <(note_block "$NOTE" "Alerts do not reach Alertmanager" 2)
check_output "discovered is 1" '"1"\]' q prometheus_notifications_alertmanagers_discovered
retry 60 bash -c "curl -fsS $A/api/v2/alerts | jq -e '.[] | select(.labels.alertname==\"Watchdog\")'" || true
check_output "3. Alertmanager has Watchdog (from the note)" $'^Watchdog\tactive$' run "Alerts do not reach Alertmanager" 3
docker compose exec alertmanager amtool --alertmanager.url=http://localhost:9093 \
  alert add alertname=DiskFull instance=web-03 severity=warning >/dev/null
eventually "4. the webhook to a name that does not resolve fails (from the note)" '"webhook"' \
  "$(note_block "$NOTE" "Alerts do not reach Alertmanager" 4)"
check_output "the log has the error (from the note)" 'no such host' run "Alerts do not reach Alertmanager" 5
check_output "alertmanager_notifications_failed_total has a reason label" 'reason="other"' \
  bash -c "docker compose exec alertmanager wget -qO- http://localhost:9093/metrics | grep '^alertmanager_notifications_failed_total{integration=\"webhook\"'"
sed -i 's/alertmanager:9093"\]/alertmanager:9999"]/' prometheus/prometheus.yml
grep -q 'alertmanager:9999' prometheus/prometheus.yml
reload
eventually "a wrong Alertmanager address: Prometheus counts errors" '"[1-9][0-9.]*"\]' \
  'sum(increase(prometheus_notifications_errors_total[2m])) > 0'
