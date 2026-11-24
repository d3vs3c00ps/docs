#!/usr/bin/env bash
# note: servers/zabbix.md
# env: leap-systemd
# timeout: 1800
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=servers/zabbix
zypper -n -q install --no-recommends podman passt openssl curl >/dev/null
block() { note_block "$NOTE" "$@"; }

# A normal user runs the pod, as the note's --user unit implies. Podman's overlay
# storage cannot sit on the Docker container's own overlay: tmpfs instead.
useradd -m zbx
Z=$(id -u zbx)
mkdir -p /home/zbx/.local/share/containers
mount -t tmpfs -o "uid=$Z,gid=$Z" tmpfs /home/zbx/.local/share/containers
chown -R zbx: /home/zbx/.local
loginctl enable-linger zbx
retry 20 test -S "/run/user/$Z/bus"
as_zbx() {
  runuser -u zbx -- env XDG_RUNTIME_DIR="/run/user/$Z" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$Z/bus" \
    HOME=/home/zbx bash -c "cd ~ && $1"
}
# Docker sets this to 0 in its containers. A normal host has 1024.
sysctl -qw net.ipv4.ip_unprivileged_port_start=1024

section "Creating the pod"
check_output "as a normal user, -p 80:8080 is refused (as the note says)" 'Failed to bind port 80 \(Permission denied\)' \
  as_zbx "$(block 'Creating the pod' 1) 2>&1 && podman pod start zabbix 2>&1; true"
as_zbx 'podman pod rm -f zabbix >/dev/null 2>&1 || true'
check "the sysctl drop-in from the note" bash -ec "$(block 'Creating the pod' 2)"
check_output "unprivileged ports start at 80" '^80$' sysctl -n net.ipv4.ip_unprivileged_port_start
check "then the pod is created (from the note)" as_zbx "$(block 'Creating the pod' 1)"

section "MySQL container"
mkdir -p /srv/zabbix/mysql /srv/zabbix/web && chown -R zbx: /srv/zabbix
check "MySQL 8.4 with utf8mb4 (from the note)" as_zbx "$(block 'MySQL container' 1)"
check "it accepts connections" retry 120 as_zbx \
  "podman exec mysql-server mysql -uzabbix -pzabbix_pwd -e 'SELECT 1' zabbix"
check_output "the zabbix user authenticates with caching_sha2_password" 'caching_sha2_password' \
  as_zbx "podman exec mysql-server mysql -uroot -proot_pwd -N -e \"SELECT plugin FROM mysql.user WHERE user='zabbix'\""
check_output "mysql_native_password is disabled by default in 8.4 (the correction)" 'DISABLED' \
  as_zbx "podman exec mysql-server mysql -uroot -proot_pwd -N -e \"SELECT plugin_status FROM information_schema.plugins WHERE plugin_name='mysql_native_password'\""

check_output "log_bin_trust_function_creators is on, so the zabbix user may create triggers" '^1$' \
  as_zbx "podman exec mysql-server mysql -uroot -proot_pwd -N -e 'SELECT @@log_bin_trust_function_creators'"
check_output "and binary logging is on by default (why it is needed)" '^1$' \
  as_zbx "podman exec mysql-server mysql -uroot -proot_pwd -N -e 'SELECT @@log_bin'"

section "Zabbix server container"
check "the server (from the note)" as_zbx "$(block 'Zabbix server container' 1)"
check "it creates the schema and starts" retry 300 as_zbx "podman logs zabbix-server-mysql 2>&1 | grep -q 'server #0 started'"
as_zbx 'podman logs zabbix-server-mysql 2>&1 | tail -40' | sed 's/^/# server log: /'
check_output "the database is utf8mb4" 'utf8mb4' \
  as_zbx "podman exec mysql-server mysql -uroot -proot_pwd -N -e \"SELECT default_character_set_name FROM information_schema.schemata WHERE schema_name='zabbix'\""

section "Java gateway container"
check "the Java gateway (from the note)" as_zbx "$(block 'Java gateway container' 1)"
check "it runs" retry 30 as_zbx "podman ps --filter name=zabbix-java-gateway --format '{{.Status}}' | grep -q Up"

section "Web front-end container"
openssl req -x509 -nodes -newkey rsa:2048 -days 30 -subj /CN=zabbix.example.com \
  -keyout /srv/zabbix/web/ssl.key -out /srv/zabbix/web/ssl.crt 2>/dev/null
chown -R zbx: /srv/zabbix/web
check "the web front-end (from the note)" as_zbx "$(block 'Web front-end container' 1)"
check_output "the UI answers on port 80 of the host" 'Zabbix' bash -c 'for i in $(seq 120); do curl -sf http://localhost/ && break; sleep 2; done'
curl -sf -o /dev/null http://localhost/ ||
  as_zbx 'podman logs zabbix-web-mysql 2>&1 | tail -30' | sed 's/^/# web log: /'

section "Agent container"
check "the agent (from the note)" as_zbx "$(block 'Agent container' 1)"
check_output "it answers agent.ping" 'agent\.ping +\[u\|1\]' \
  as_zbx 'podman exec zabbix-agent zabbix_agentd -t agent.ping'

section "Running the pod as a service"
check "mkdir and cd (from the note)" as_zbx "$(block 'Running the pod as a service' 1)"
check_output "podman generate systemd --files (from the note) prints DEPRECATED" 'DEPRECATED' \
  as_zbx "cd ~/.config/systemd/user && $(block 'Running the pod as a service' 2) 2>&1"
check "it wrote pod-zabbix.service" test -f /home/zbx/.config/systemd/user/pod-zabbix.service
check "daemon-reload (from the note)" as_zbx "$(block 'Running the pod as a service' 3)"
check "enable --now (from the note)" as_zbx "$(block 'Running the pod as a service' 4)"
check_output "is-active (from the note)" '^active$' as_zbx "$(note_block "$NOTE" 'Running the pod as a service' 5 | sed -n 's/^\$ //p')"
check_output "lingering is on, so it starts at boot" 'Linger=yes' loginctl show-user zbx -p Linger
