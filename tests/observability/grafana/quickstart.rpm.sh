#!/usr/bin/env bash
# note: observability/grafana/quickstart.md
# env: rocky-systemd
# timeout: 1200
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=observability/grafana/quickstart
install=$(note_block "$NOTE" "Install from the package repository")

section "Install from the package repository"
assert_match "the note installs the version of versions.env" "grafana-$GRAFANA_VERSION\$" "$install"
# The last line (curl) runs later: Grafana needs a few seconds after systemctl returns.
check "add the repository, dnf install, enable --now (from the note)" \
  bash -c 'bash -ec "$1" >/tmp/install.log 2>&1 || { tail -20 /tmp/install.log; exit 1; }' _ "$(sed '$d' <<<"$install")"
check_output "the package is installed" "^grafana-$GRAFANA_VERSION-" rpm -q grafana
check_output "grafana-server is active" '^active$' bash -c 'sleep 5; systemctl is-active grafana-server'
check_output "and enabled" '^enabled$' systemctl is-enabled grafana-server
for i in $(seq 90); do curl -fs http://localhost:3000/api/health >/dev/null && break; sleep 1; done
check_output "/api/health (from the note)" "\"version\": \"$GRAFANA_VERSION\"" bash -ec "$(tail -1 <<<"$install")"
assert_file "the configuration is /etc/grafana/grafana.ini" /etc/grafana/grafana.ini
check "the data is in /var/lib/grafana" test -f /var/lib/grafana/grafana.db
check "the logs are in /var/log/grafana" test -d /var/log/grafana
check "the provisioning folder is /etc/grafana/provisioning" test -d /etc/grafana/provisioning/datasources
