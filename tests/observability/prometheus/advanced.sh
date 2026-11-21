#!/usr/bin/env bash
# note: observability/prometheus/advanced.md
# env: compose
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=observability/prometheus/advanced
P=http://localhost:9090
A=http://localhost:9093

# q EXPR: the JSON result of an instant query.
q() { curl -fsS "$P/api/v1/query" --data-urlencode "query=$1" | jq -c .data.result; }
# has EXPR: the query returns at least one series.
has() { [[ $(q "$1") != "[]" ]]; }
# run HEADING [N]: run a shell block of the note.
run() { bash -ec "$(note_block "$NOTE" "$1" "${2:-1}")"; }
# replace_job FILE BLOCK: replace the 3-line "prometheus" job of FILE by BLOCK.
replace_job() {
  python3 - "$1" "$2" <<'EOF'
import sys
path, new = sys.argv[1], sys.argv[2]
old = '  - job_name: prometheus\n    static_configs:\n      - targets: ["localhost:9090"]\n'
s = open(path).read()
assert old in s, "the prometheus job is not in its original form"
open(path, "w").write(s.replace(old, new.rstrip("\n") + "\n"))
EOF
}
reload() { curl -fsS -X POST "$P/-/reload"; }
# eventually DESC REGEX EXPR: the query result matches REGEX within 45 s (self-metrics need a scrape).
eventually() {
  retry 45 bash -c "curl -fsS '$P/api/v1/query' --data-urlencode 'query=$3' | jq -c .data.result | grep -Eq -- '$2'" || true
  check_output "$1" "$2" q "$3"
}
# htpasswd is not in the runner: use the one of the Apache httpd image.
htpasswd() { docker run --rm httpd:2.4-alpine htpasswd "$@"; }
export -f htpasswd

section "The lab"
mkdir -p prometheus/rules prometheus/targets prometheus/tests alertmanager
note_block "$NOTE" "The lab" 2 >compose.yaml
note_block "$NOTE" "The lab" 3 >prometheus/prometheus.yml
note_block "$NOTE" "### file_sd" 1 >prometheus/targets/node.yml
note_block "$NOTE" "Recording and alerting rules" 1 >prometheus/rules/node.yml
note_block "$NOTE" "Unit tests for rules" 1 >prometheus/tests/node_test.yml
note_block "$NOTE" "## Alertmanager" 1 >alertmanager/alertmanager.yml
tree=$(note_block "$NOTE" "The lab" 1)
for f in compose.yaml prometheus/prometheus.yml prometheus/rules/node.yml prometheus/targets/node.yml \
  prometheus/tests/node_test.yml alertmanager/alertmanager.yml; do
  assert_match "the tree lists $f" "$(basename "$f")" "$tree"
done
check_output "the images are the versions of versions.env" "prometheus:$PROMETHEUS_VERSION" cat compose.yaml
check_output "alertmanager too" "alertmanager:$ALERTMANAGER_VERSION" cat compose.yaml
check_output "promtool check config also checks the rule files" 'SUCCESS: 4 rules found' \
  docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" --entrypoint promtool \
  "prom/prometheus:$PROMETHEUS_VERSION" check config /etc/prometheus/prometheus.yml
docker compose up -d --quiet-pull 2>/dev/null
wait_http "$P/-/ready" 90 || compose_logs prometheus
wait_http "$A/-/ready" 60 || compose_logs alertmanager
check_output "both answer ready (from the note)" 'Prometheus Server is Ready.*OK|Ready' run "The lab" 4
check_fails "Alertmanager cluster mode is off: nothing listens on 9094" \
  docker compose exec alertmanager sh -c 'netstat -ltn | grep -q ":9094 "'
retry 60 has 'up{job="node"} == 1' || true
retry 60 has 'count({job="prometheus", __name__=~"go_.*"})' || true

section "Relabelling"
promql=$(note_block "$NOTE" "Relabelling" 1)
check_output "instance has no port (from the note)" '"instance":"node-exporter"' q "$(sed -n 1p <<<"$promql")"
assert_eq "no go_* series stored for node (from the note)" "[]" "$(q "$(sed -n 2p <<<"$promql")")"
check "the prometheus job still has its go_* series" has 'count({job="prometheus", __name__=~"go_.*"})'
check_output "node_exporter itself still exposes them" '^go_goroutines' \
  bash -c "docker compose exec prometheus wget -qO- http://node-exporter:9100/metrics | grep -m1 '^go_goroutines'"

section "file_sd"
check_output "the group label env=lab is on the target" '"env":"lab"' q 'up{job="node"}'
check_output "__meta_filepath is in the discovered labels" '/etc/prometheus/targets/node.yml' \
  bash -c "curl -fsS $P/api/v1/targets | jq -r '.data.activeTargets[] | select(.labels.job==\"node\") | .discoveredLabels.__meta_filepath'"
# Write to a temporary file and rename it, as the note says.
printf -- '- targets: ["alertmanager:9093"]\n  labels:\n    env: extra\n' >prometheus/targets/.extra.tmp
mv prometheus/targets/.extra.tmp prometheus/targets/extra.yml
if retry 60 has 'up{job="node", env="extra"}'; then
  check "a new file is used without a reload" true
else
  skip "a new file is used without a reload" \
    "no inotify event through the Docker Desktop bind mount in 60 s; Prometheus re-reads the files every 5 min"
fi
rm prometheus/targets/extra.yml

section "http_sd"
mkdir -p sd
note_block "$NOTE" "### http_sd" 1 >sd/targets.json
cat >sd.yaml <<'EOF'
services:
  sd:
    image: prom/prometheus:${PROMETHEUS_VERSION}
    entrypoint: ["httpd", "-f", "-p", "8000", "-h", "/www"]
    volumes:
      - ./sd:/www:ro
EOF
PROMETHEUS_VERSION=$PROMETHEUS_VERSION docker compose -f compose.yaml -f sd.yaml up -d sd 2>/dev/null
note_block "$NOTE" "### http_sd" 2 >>prometheus/prometheus.yml
check "the http_sd job is valid, reload" reload
# busybox httpd sends no Content-Type for .json: Prometheus refuses the answer.
retry 30 bash -c "docker compose logs prometheus 2>&1 | grep -qi 'content.type'" || true
check_output "without Content-Type: application/json, http_sd refuses the list" '[Cc]ontent.[Tt]ype' \
  bash -c "docker compose logs prometheus 2>&1 | grep -i 'content.type' | tail -1"
printf '.json:application/json\n' >sd/httpd.conf
cat >sd.yaml <<'EOF'
services:
  sd:
    image: prom/prometheus:${PROMETHEUS_VERSION}
    entrypoint: ["httpd", "-f", "-p", "8000", "-h", "/www", "-c", "/www/httpd.conf"]
    volumes:
      - ./sd:/www:ro
EOF
PROMETHEUS_VERSION=$PROMETHEUS_VERSION docker compose -f compose.yaml -f sd.yaml up -d sd 2>/dev/null
check_output "with the header" '[Cc]ontent-[Tt]ype: application/json' \
  docker compose exec prometheus wget -S -qO /dev/null http://sd:8000/targets.json
# Prometheus asks the endpoint again only every refresh_interval (1m), then scrapes.
retry 150 has 'up{job="node-http-sd", env="from-http"} == 1' || true
check "the target from http_sd is scraped with its label" has 'up{job="node-http-sd", env="from-http"} == 1'
check_output "promtool check service-discovery (from the note)" '"__address__": "node-exporter:9100"' run "### http_sd" 3

section "Recording and alerting rules"
check_output "promtool check rules (from the note)" 'SUCCESS: 4 rules found' run "Recording and alerting rules" 2
check_output "promtool test rules (from the note)" 'SUCCESS' run "Unit tests for rules" 2
sed 's/severity: critical/severity: warning/' prometheus/tests/node_test.yml >prometheus/tests/bad_test.yml
check_fails "a wrong expectation makes promtool test rules fail" \
  docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" --entrypoint promtool \
  "prom/prometheus:$PROMETHEUS_VERSION" test rules /etc/prometheus/tests/bad_test.yml
sed 's/eval_time: 3m/eval_time: 4m/' prometheus/tests/node_test.yml >prometheus/tests/bad_test.yml
check_fails "at 4m the alert already fires (2m down = for: 2m)" \
  docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" --entrypoint promtool \
  "prom/prometheus:$PROMETHEUS_VERSION" test rules /etc/prometheus/tests/bad_test.yml
rm prometheus/tests/bad_test.yml
retry 90 has 'instance:node_cpu_utilisation:rate5m' || true
check_output "the recording rule writes its series" '"instance":"node-exporter"' q 'instance:node_cpu_utilisation:rate5m'
check_output "Watchdog fires in Prometheus" '"state":"firing"' \
  bash -c "curl -fsS $P/api/v1/alerts | jq -c '.data.alerts[] | select(.labels.alertname==\"Watchdog\")'"

section "Alertmanager"
out=$(run "## Alertmanager" 2)
assert_match "amtool check-config (from the note)" 'SUCCESS' "$out"
assert_match "a critical alert goes to team-ops-pager (from the note)" '^team-ops-pager$' "$out"
amroute() {
  docker run --rm -v "$PWD/alertmanager:/etc/alertmanager:ro" --entrypoint amtool "prom/alertmanager:$ALERTMANAGER_VERSION" \
    config routes test --config.file=/etc/alertmanager/alertmanager.yml "$@"
}
check_output "Watchdog goes to null" '^null$' amroute alertname=Watchdog severity=none
check_output "a warning goes to the root receiver" '^team-ops$' amroute alertname=HostHighCpu severity=warning
sed 's/receiver: team-ops$/receiver: nobody/' alertmanager/alertmanager.yml >alertmanager/bad.yml
check_fails "check-config fails on an unknown receiver" \
  docker run --rm -v "$PWD/alertmanager:/etc/alertmanager:ro" --entrypoint amtool \
  "prom/alertmanager:$ALERTMANAGER_VERSION" check-config /etc/alertmanager/bad.yml
rm alertmanager/bad.yml
retry 60 bash -c "curl -fsS '$A/api/v2/alerts' | jq -e '.[] | select(.labels.alertname==\"Watchdog\")'" || true
check_output "Prometheus sends Watchdog to Alertmanager, with external_labels" '"site":"lab"' \
  bash -c "curl -fsS '$A/api/v2/alerts' | jq -c '.[] | select(.labels.alertname==\"Watchdog\") | .labels'"

section "Silences with amtool"
out=$(run "Silences with amtool" 1)
assert_match "silence add prints an ID, silence query lists it (from the note)" 'instance="web-01"' "$out"
id=$(head -1 <<<"$out")
assert_match "the first line is the silence ID" '^[0-9a-f-]{36}$' "$id"
docker compose exec alertmanager amtool --alertmanager.url=http://localhost:9093 \
  alert add alertname=HostHighCpu instance=web-01 severity=warning >/dev/null
retry 10 bash -c "curl -fsS '$A/api/v2/alerts?silenced=true' | jq -e '.[] | select(.labels.instance==\"web-01\")'" || true
check_output "an alert of web-01 is silenced" "\"$id\"" \
  bash -c "curl -fsS '$A/api/v2/alerts?silenced=true' | jq -c '.[] | select(.labels.instance==\"web-01\") | .status.silencedBy'"
check "silence expire ID" docker compose exec alertmanager amtool --alertmanager.url=http://localhost:9093 silence expire "$id"
out=$(run "Silences with amtool" 2)
assert_match "InstanceDown is active (from the note)" $'^InstanceDown\tactive$' "$out"
assert_match "HostHighCpu of the same instance is suppressed" $'^HostHighCpu\tsuppressed$' "$out"
check_output "it is inhibited, not silenced" '"inhibitedBy":\["[0-9a-f]+' \
  bash -c "curl -fsS '$A/api/v2/alerts' | jq -c '.[] | select(.labels.instance==\"web-02\" and .labels.alertname==\"HostHighCpu\") | .status'"

section "Retention"
check_output "the retention of the lab (from the note)" '30d or 10GiB' run "## Retention" 2
check "the retention block is the one of the lab" grep -q "$(note_block "$NOTE" "## Retention" 1 | sed -n 4p)" prometheus/prometheus.yml
sed -i 's/      time: 30d/      time: 20d/' prometheus/prometheus.yml
reload
check_output "a reload applies a new retention" '20d or 10GiB' run "## Retention" 2

section "Reload the configuration"
check "curl -X POST /-/reload and SIGHUP (from the note)" run "Reload the configuration" 1
check_output "the SIGHUP reload is logged" 'Completed loading of configuration file' compose_logs prometheus
check_output "prometheus_config_last_reload_successful is 1" '"1"\]' q "$(note_block "$NOTE" "Reload the configuration" 2)"
cp prometheus/prometheus.yml prometheus/good.yml
echo 'scrape_configs: [' >>prometheus/prometheus.yml
check_output "a bad file: /-/reload answers HTTP 500 with the error" 'parsing YAML file.* 500 $' \
  bash -c "curl -s -o /dev/stderr -w '%{http_code} ' -X POST $P/-/reload 2>&1 | tr '\n' ' '"
eventually "the metric is 0" '"0"\]' prometheus_config_last_reload_successful
check "Prometheus keeps running" curl -fsS "$P/-/ready"
check_output "with the old configuration" 'job_name: node-http-sd' \
  bash -c "curl -fsS $P/api/v1/status/config | jq -r .data.yaml"
cp prometheus/good.yml prometheus/prometheus.yml
reload
eventually "after a fix, the metric is 1 again" '"1"\]' prometheus_config_last_reload_successful
check "Alertmanager reloads with POST /-/reload" curl -fsS -X POST "$A/-/reload"
eventually "alertmanager_config_last_reload_successful is 1" '"1"\]' alertmanager_config_last_reload_successful

section "Remote write"
cat >remote.yaml <<'EOF'
services:
  remote:
    image: prom/prometheus:${PROMETHEUS_VERSION}
    command: ["--config.file=/etc/prometheus/prometheus.yml", "--web.enable-remote-write-receiver"]
EOF
PROMETHEUS_VERSION=$PROMETHEUS_VERSION docker compose -f compose.yaml -f remote.yaml up -d remote 2>/dev/null
note_block "$NOTE" "Remote write" 1 >>prometheus/prometheus.yml
check "the remote_write block is valid, reload" reload
rq() { docker compose exec remote promtool query instant http://localhost:9090 "$1"; }
retry 60 bash -c "docker compose exec remote promtool query instant http://localhost:9090 'up{site=\"lab\"}' | grep -q site" || true
check_output "the remote gets up, with the external label site=lab" 'up\{.*site="lab"' rq 'up{site="lab"}'
retry 30 bash -c "docker compose exec remote promtool query instant http://localhost:9090 'instance:node_cpu_utilisation:rate5m' | grep -q site" || true
check_output "and the recording rules" 'instance:node_cpu_utilisation:rate5m' rq 'instance:node_cpu_utilisation:rate5m{site="lab"}'
check_output "but not the other series (write_relabel_configs keep)" '^$' rq 'node_cpu_seconds_total{site="lab"}'
eventually "samples were sent" '"[1-9][0-9]*"\]' 'sum(prometheus_remote_storage_samples_total)'
check_output "prometheus_remote_storage_highest_timestamp_in_seconds exists" 'value' \
  q prometheus_remote_storage_highest_timestamp_in_seconds

section "Native histograms and UTF-8 names"
replace_job prometheus/prometheus.yml "$(note_block "$NOTE" "Native histograms and UTF-8 names" 1)"
reload
sleep 35
check_output "histogram_quantile on the native histogram (from the note)" '"value"' \
  q "$(note_block "$NOTE" "Native histograms and UTF-8 names" 2)"
assert_eq "the _bucket series of that job are gone" "[]" \
  "$(q 'prometheus_http_request_duration_seconds_bucket{job="prometheus"}')"
check "always_scrape_classic_histograms is a valid key" \
  docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" --entrypoint sh "prom/prometheus:$PROMETHEUS_VERSION" -c \
  'sed "s/scrape_native_histograms: true/scrape_native_histograms: true\n    always_scrape_classic_histograms: true/" /etc/prometheus/prometheus.yml >/tmp/p.yml && promtool check config --syntax-only /tmp/p.yml'
check_output "the quoted UTF-8 query is valid (from the note)" '"status":"success"' \
  curl -fsS "$P/api/v1/query" --data-urlencode "query=$(note_block "$NOTE" "Native histograms and UTF-8 names" 3)"
assert_eq '{"up", job="node"} is the same as up{job="node"}' "$(q 'up{job="node"}' | jq -c '.[].metric')" "$(q '{"up", job="node"}' | jq -c '.[].metric')"

section "Useful PromQL patterns"
i=0
while IFS= read -r line; do
  [[ -z $line || $line == \#* ]] && continue
  i=$((i + 1))
  check_output "query $i is valid: $line" '"status":"success"' \
    curl -fsS "$P/api/v1/query" --data-urlencode "query=$line"
done < <(note_block "$NOTE" "Useful PromQL patterns" 1)
assert_eq "the note has six queries" 6 "$i"
check "rate gives a value" has 'rate(node_network_receive_bytes_total[5m])'
check "the classic histogram_quantile works on the alertmanager job" \
  has 'histogram_quantile(0.95, sum by (le, handler) (rate(alertmanager_http_request_duration_seconds_bucket[5m])))'
assert_eq "absent() is empty while the series exist" "[]" "$(q 'absent(up{job="node"})')"
check_output "absent() is 1 when nothing matches" '"1"\]' q 'absent(up{job="missing"})'

section "TLS and basic auth"
check "openssl and htpasswd (from the note)" bash -ec "$(note_block "$NOTE" "TLS and basic auth" 1) >hash.txt"
hash=$(tail -c 60 hash.txt)
assert_match "htpasswd prints a bcrypt hash" '^\$2y\$10\$' "$hash"
note_block "$NOTE" "TLS and basic auth" 2 | sed "s|\$2y\$10\$REPLACE.WITH.THE.HASH.FROM.HTPASSWD|$hash|" >prometheus/web.yml
check_output "promtool check web-config (from the note)" 'SUCCESS' run "TLS and basic auth" 3
note_block "$NOTE" "TLS and basic auth" 4 >compose.override.yaml
cp prometheus/prometheus.yml prometheus/plain.yml
python3 - prometheus/prometheus.yml "$(note_block "$NOTE" "TLS and basic auth" 5)" <<'EOF'
import re, sys
path, new = sys.argv[1], sys.argv[2]
s = open(path).read()
s, n = re.subn(r'  - job_name: prometheus\n(    .*\n|      .*\n)+', new.rstrip("\n") + "\n", s, count=1)
assert n == 1
open(path, "w").write(s)
EOF
up_tls=$(note_block "$NOTE" "TLS and basic auth" 6)
bash -ec "$(sed -n 1p <<<"$up_tls")" 2>/dev/null
retry 60 curl -fsS --cacert prometheus/tls/prometheus.crt -u admin:change-me https://localhost:9090/-/ready || true
check_output "compose up with the override, ready over TLS with the password (from the note)" 'Prometheus Server is Ready' \
  bash -ec "$(sed -n 2p <<<"$up_tls")"
check_output "without the password: 401" '^401$' \
  curl -s -o /dev/null -w '%{http_code}' --cacert prometheus/tls/prometheus.crt https://localhost:9090/-/ready
check_output "a wrong password: 401" '^401$' \
  curl -s -o /dev/null -w '%{http_code}' --cacert prometheus/tls/prometheus.crt -u admin:wrong https://localhost:9090/-/ready
check_fails "plain HTTP no longer works" curl -fsS http://localhost:9090/-/ready
tq() { curl -fsS --cacert prometheus/tls/prometheus.crt -u admin:change-me "https://localhost:9090/api/v1/query" --data-urlencode "query=$1" | jq -c .data.result; }
retry 40 bash -c "[ \"\$(curl -fsS --cacert prometheus/tls/prometheus.crt -u admin:change-me https://localhost:9090/api/v1/query --data-urlencode 'query=up{job=\"prometheus\"}' | jq -r '.data.result[0].value[1]')\" = 1 ]" || true
check_output "the self-scrape over https with basic auth is up" '"1"\]' tq 'up{job="prometheus"}'
cp prometheus/plain.yml prometheus/prometheus.yml
curl -s --cacert prometheus/tls/prometheus.crt -u admin:change-me -X POST https://localhost:9090/-/reload >/dev/null
retry 40 bash -c "curl -fsS --cacert prometheus/tls/prometheus.crt -u admin:change-me https://localhost:9090/api/v1/targets | jq -e '.data.activeTargets[] | select(.labels.job==\"prometheus\" and .health==\"down\")'" || true
check_output "with the old job, the self target goes down, as the note warns" 'HTTP response to HTTPS client|server returned HTTP status 400' \
  bash -c "curl -fsS --cacert prometheus/tls/prometheus.crt -u admin:change-me https://localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | select(.labels.job==\"prometheus\") | .lastError'"
