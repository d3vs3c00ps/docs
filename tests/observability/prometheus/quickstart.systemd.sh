#!/usr/bin/env bash
# note: observability/prometheus/quickstart.md
# env: leap-systemd
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=observability/prometheus/quickstart
zypper -n -q install --no-recommends shadow >/dev/null 2>&1 || true

# The blocks share variables (PROM_VERSION, ARCH) and the working directory, as in a
# terminal session, so they run in one shell.
download=$(note_block "$NOTE" "Download and check the checksum")
users=$(note_block "$NOTE" "Create the user and the folders")

section "Download and check the checksum"
check_output "download and sha256sum --check (from the note)" \
  "prometheus-[0-9.]+\.linux-(amd64|arm64)\.tar\.gz: OK" bash -ec "$download"
source "$NOTES_ROOT/tests/versions.env"
assert_match "the note downloads the version of versions.env" "PROM_VERSION=${PROMETHEUS_VERSION#v}\$" "$download"
cp /tmp/sha256sums.txt /tmp/sums.bad
sed -i -E 's/^[0-9a-f]{8}/00000000/' /tmp/sums.bad
check_output "a wrong checksum prints FAILED" 'FAILED' \
  bash -c 'cd /tmp && sha256sum --check --ignore-missing sums.bad 2>&1; true'
check_fails "and sha256sum exits non-zero" bash -c 'cd /tmp && sha256sum --check --ignore-missing sums.bad'

section "Create the user and the folders"
check "useradd, install (from the note)" bash -ec "$(head -3 <<<"$download")
$users"
check_output "prometheus is a system user with nologin" '^prometheus:x:[0-9]+:[0-9]+::.*:/usr/sbin/nologin$' getent passwd prometheus
check_output "the binary is installed" "prometheus, version ${PROMETHEUS_VERSION#v}" /usr/local/bin/prometheus --version
check "promtool too" test -x /usr/local/bin/promtool
check_output "the data folder belongs to prometheus" '^prometheus prometheus 750$' stat -c '%U %G %a' /var/lib/prometheus

section "The configuration"
note_block "$NOTE" "The configuration" >/etc/prometheus/prometheus.yml
note_block "$NOTE" "The unit file" >/etc/systemd/system/prometheus.service

section "The unit file"
start=$(note_block "$NOTE" "The unit file" 2)
check_output "promtool check config, start, /-/ready (from the note)" 'Prometheus Server is Ready' \
  bash -ec "${start/curl -s/sleep 5; curl -s --retry 20 --retry-connrefused --retry-delay 1}"
check_output "the service is active" '^active$' systemctl is-active prometheus
check_output "the service is enabled" '^enabled$' systemctl is-enabled prometheus
check_output "it runs as the prometheus user" '^prometheus$' ps -o user= -C prometheus
check "the TSDB is in /var/lib/prometheus" test -d /var/lib/prometheus/wal
check_output "the retention block is used (30d or 20GB)" '30d.*20GiB|20GiB.*30d' \
  bash -c 'curl -fsS http://localhost:9090/api/v1/status/runtimeinfo | jq -r .data.storageRetention'
check_output "the unit uses ProtectSystem=strict" '^ProtectSystem=strict$' systemctl show prometheus -p ProtectSystem
check_fails "ProtectSystem=strict: even root cannot write to /etc" \
  systemd-run --wait --quiet -p ProtectSystem=strict /usr/bin/touch /etc/x
check "but it can write to ReadWritePaths" \
  systemd-run --wait --quiet -p ProtectSystem=strict -p ReadWritePaths=/var/lib/prometheus /usr/bin/touch /var/lib/prometheus/x
rm -f /var/lib/prometheus/x
check_output "the lifecycle API is on: /-/reload works" '^$' curl -fsS -X POST http://localhost:9090/-/reload

reload=$(note_block "$NOTE" "The unit file" 3)
sed -i 's/scrape_interval: 15s/scrape_interval: 20s/' /etc/prometheus/prometheus.yml
check "promtool check and systemctl reload (from the note)" bash -ec "$reload"
retry 10 bash -c "curl -fsS http://localhost:9090/api/v1/status/config | jq -r .data.yaml | grep -q 'scrape_interval: 20s'" || true
check_output "the reload applied the new interval" 'scrape_interval: 20s' \
  bash -c 'curl -fsS http://localhost:9090/api/v1/status/config | jq -r .data.yaml'
check_output "systemctl reload sends SIGHUP: the reload is logged" 'Completed loading of configuration file' \
  journalctl -u prometheus --no-pager
check_output "the service did not restart" '^1$' bash -c "journalctl -u prometheus --no-pager | grep -c 'Starting Prometheus Server'"
echo 'global: [' >>/etc/prometheus/prometheus.yml
check_fails "with a broken file, promtool stops before the reload (from the note)" bash -ec "$reload"

section "The retention flags are deprecated"
note_block "$NOTE" "The configuration" >/etc/prometheus/prometheus.yml
mkdir -p /etc/systemd/system/prometheus.service.d
cat >/etc/systemd/system/prometheus.service.d/flag.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/local/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus --web.enable-lifecycle --storage.tsdb.retention.time=10d
EOF
systemctl daemon-reload
systemctl restart prometheus
retry 30 curl -fsS http://localhost:9090/-/ready || true
check_output "the file wins over the flag: retention stays 30d" '30d' \
  bash -c 'curl -fsS http://localhost:9090/api/v1/status/runtimeinfo | jq -r .data.storageRetention'
check_output "prometheus --help marks the flag [DEPRECATED]" '\[DEPRECATED\] How long to retain' \
  bash -c '/usr/local/bin/prometheus --help 2>&1 | grep -A1 "retention.time="'
check_output "no deprecation warning in the logs" '^0$' \
  bash -c "journalctl -u prometheus --no-pager | grep -ci deprecat || true"
# Without the retention block, the flag still applies.
sed -i '/^storage:/,/^$/d' /etc/prometheus/prometheus.yml
systemctl restart prometheus
retry 30 curl -fsS http://localhost:9090/-/ready || true
check_output "the flag still works without the block: 10d" '^10d$' \
  bash -c 'curl -fsS http://localhost:9090/api/v1/status/runtimeinfo | jq -r .data.storageRetention'
