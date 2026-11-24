#!/usr/bin/env bash
# note: servers/vaultwarden-podman.md
# env: leap-systemd
# timeout: 1500
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=servers/vaultwarden-podman
zypper -n -q install --no-recommends podman passt openssl curl >/dev/null
block() { note_block "$NOTE" "$@"; }

section "Installing and configuring rootless Podman"
check_output "Podman 5 uses pasta for rootless networking (as the note says)" '^podman version 5\.' podman --version
check_output "cgroup v2 (the note's check)" '^cgroup2fs$' bash -ec "$(sed -n 's/.*Confirm with `\(stat -fc %T \/sys\/fs\/cgroup\/\)`.*/\1/p' "$NOTES_ROOT/content/$NOTE.md")"
skip "kernel command line and transactional-update grub.cfg" "MicroOS boot settings: a container has no bootloader or kernel of its own"

section "Sysctl settings"
# The note's file, then only that file: `sysctl --system` would also apply the
# distribution's kernel-wide settings to the shared Docker host.
check "the sysctl.d drop-in (from the note)" bash -ec "$(block 'Sysctl settings' 1 | sed -n '/^cat /,/^EOF/p')"
check "sysctl -p on it" sysctl -p /etc/sysctl.d/99-podman.conf
check_output "unprivileged ports now start at 443" '^443$' sysctl -n net.ipv4.ip_unprivileged_port_start

section "Service user"
# Podman's overlay storage cannot sit on the Docker container's own overlay.
check "useradd and enable-linger (from the note)" bash -ec "$(block 'Service user' 1)"
U=$(id -u podman)
mkdir -p /home/podman && chown podman: /home/podman
mkdir -p /home/podman/.local/share/containers
mount -t tmpfs -o "uid=$U,gid=$U" tmpfs /home/podman/.local/share/containers
chown -R podman: /home/podman/.local
check "the user's systemd runs with no session (linger)" retry 20 test -S "/run/user/$U/bus"
check_output "useradd gave podman a subuid range" '^podman:[0-9]+:65536$' grep '^podman:' /etc/subuid
as_podman() {
  runuser -u podman -- env XDG_RUNTIME_DIR="/run/user/$U" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$U/bus" \
    HOME=/home/podman bash -c "cd ~ && $1"
}

section "Preparing the volumes"
check "mkdir (from the note)" as_podman "$(block 'Preparing the volumes' 1)"
block 'Preparing the volumes' 2 >/home/podman/nx-data/vaultwarden.conf
block 'Certificate' 1 >/home/podman/nx-data/req.conf
chown -R podman: /home/podman/nx-data
check "openssl req (from the note)" as_podman "$(block 'Certificate' 2)"
check_output "the SAN uses the internal example domain" 'DNS:vaultwarden\.internal\.example\.com' \
  openssl x509 -in /home/podman/nx-data/vaultwarden.crt -noout -ext subjectAltName

section "Creating the pod and containers"
# Before any pull: once an image is local, its short name resolves to it.
check_output "a short name is tried on the openSUSE registries first (as the note says)" \
  'Trying to pull registry\.opensuse\.org/vaultwarden/server' \
  as_podman 'podman pull vaultwarden/server:latest 2>&1 </dev/null; true'
as_podman 'podman pull -q docker.io/library/mariadb:latest docker.io/vaultwarden/server:latest docker.io/library/nginx:latest >/dev/null'
check "network and pod with -p 443:443, as a normal user (from the note)" as_podman "$(block 'Creating the pod' 1)"
fill() { sed 's/<root password>/rootpw/; s/<user password>/vwpw/; s/<database>/vw/g; s/<user>/vw/; s/<password>/vwpw/;
  s|<argon2 hash of the admin token>|admin-token|'; }
check "MariaDB (from the note)" as_podman "$(block 'Creating the pod' 2 | fill)"
check "Vaultwarden (from the note)" as_podman "$(block 'Creating the pod' 3 | fill)"
check "nginx (from the note)" as_podman "$(block 'Creating the pod' 4 | fill)"
check "the vault answers on https://localhost/ through the pod" retry 120 curl -skf -o /dev/null https://localhost/alive
check_output "the web vault" '<title[^>]*>Vaultwarden Web</title>' curl -sk https://localhost/
check_output "Vaultwarden reaches MariaDB on 127.0.0.1 in the pod: its tables are there" '^users$' \
  as_podman "podman exec mariadb-server mariadb -uvw -pvwpw vw -N -e 'show tables'"

section "Persisting the pod"
check "podman kube generate (from the note)" as_podman "$(block 'Persisting the pod' 1)"
check_output "it writes a Pod manifest" '^kind: Pod$' cat /home/podman/vaultwarden.yml
check "stop, rm, kube play (from the note)" as_podman "$(block 'Persisting the pod' 2)"
check "the vault answers again" retry 120 curl -skf -o /dev/null https://localhost/alive
check_output "the pod is on the vaultwarden network again" 'vaultwarden' \
  as_podman "podman pod inspect vaultwarden --format '{{.InfraConfig.Networks}}'"
check "--replace does both steps" as_podman 'podman kube play --replace --network vaultwarden vaultwarden.yml >/dev/null'
check "the old names still work: generate kube" as_podman 'podman generate kube vaultwarden >/dev/null'
check "and play kube" as_podman 'podman play kube --help >/dev/null'
as_podman 'podman kube play --replace vaultwarden.yml >/dev/null'
check_fails "without --network, the replayed pod is not on the vaultwarden network (why the note adds it)" \
  as_podman "podman pod inspect vaultwarden --format '{{.InfraConfig.Networks}}' | grep -q vaultwarden"
