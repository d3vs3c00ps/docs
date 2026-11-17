#!/usr/bin/env bash
# note: containers/podman.md
# env: leap-systemd
# timeout: 1500
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=containers/podman
zypper -n -q install --no-recommends podman passt docker-compose curl >/dev/null

# Podman's overlay storage cannot sit on the Docker container's own overlay: every
# exec fails with "invalid argument". tmpfs is a filesystem it can use.
mkdir -p /var/lib/containers && mount -t tmpfs tmpfs /var/lib/containers
useradd -m alice
A=$(id -u alice)
mkdir -p /home/alice/.local/share/containers
mount -t tmpfs -o "uid=$A,gid=$A" tmpfs /home/alice/.local/share/containers
chown -R alice: /home/alice/.local
# Docker sets this to 0 in its containers. A normal host has 1024.
sysctl -qw net.ipv4.ip_unprivileged_port_start=1024
loginctl enable-linger alice
retry 20 test -S "/run/user/$A/bus"

# as_alice CMD: run CMD as alice, in her home, with her user session's environment.
as_alice() {
  runuser -u alice -- env XDG_RUNTIME_DIR="/run/user/$A" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$A/bus" \
    HOME=/home/alice bash -c "cd ~ && $1"
}
block() { note_block "$NOTE" "$@"; }

section "Rootless mechanics"
check_output "alice has a subuid range" '^alice:[0-9]+:65536$' grep '^alice:' /etc/subuid
check_output "podman unshare: container root is alice, then the subuid range (from the note)" \
  "^ *0 +$A +1\$" as_alice "$(block 'Rootless mechanics' 3 | sed -n 1p)"
check_output "podman info shows the same mappings (from the note)" "\\{0 $A 1\\}" as_alice "$(block 'Rootless mechanics' 3 | sed -n 2p)"
check_output "networking uses pasta" 'pasta' as_alice "podman info --format '{{.Host.RootlessNetworkCmd}}'"
as_alice 'podman pull -q docker.io/library/nginx:alpine docker.io/library/alpine >/dev/null'
check_fails "a normal user cannot publish port 443" as_alice 'podman run -d --rm --name low -p 443:80 docker.io/library/nginx:alpine'
check "the note's sysctl lowers the limit" bash -ec "$(block 'Rootless mechanics' 1 | grep '^sysctl')"
check "and the sysctl.d file makes it last (from the note)" bash -ec "$(block 'Rootless mechanics' 1 | grep '^echo')"
check_output "the file has the setting" '= 443$' cat /etc/sysctl.d/50-unprivileged-ports.conf
check "then port 443 works" as_alice 'podman run -d --rm --name low -p 443:80 docker.io/library/nginx:alpine'
check "and answers" retry 10 curl -sf -o /dev/null http://127.0.0.1:443/
as_alice 'podman stop -t 0 low >/dev/null'
sysctl -qw net.ipv4.ip_unprivileged_port_start=1024
check "enable-linger (from the note)" bash -ec "$(block 'Rootless mechanics' 2 | grep '^loginctl' | sed 's/"\$USER"/alice/')"
check_output "with lingering, alice's systemd runs with no session open" 'Linger=yes' loginctl show-user alice -p Linger
check "and user@$A.service is active" systemctl is-active "user@$A.service"

section "File ownership"
as_alice 'mkdir -p data && chmod 777 data'
as_alice 'podman run --rm -v ./data:/d docker.io/library/alpine sh -c "touch /d/by-root; adduser -D -u 1000 u; su u -c \"touch /d/by-1000\""'
check_output "a file written by root in the container belongs to alice (the correction)" "^$A:$A\$" stat -c '%u:%g' /home/alice/data/by-root
start=$(awk -F: '$1 == "alice" { print $2 }' /etc/subuid)
check_output "a file written by uid 1000 in the container belongs to a subuid" "^$((start + 999)):" stat -c '%u:%g' /home/alice/data/by-1000
check_fails "so alice cannot edit it directly" as_alice 'echo x >>data/by-1000'
check "podman unshare chown gives it back (from the note)" as_alice "$(block 'File ownership' 1)"
check_output "now alice owns both files" "^$A\$" bash -c "stat -c '%u' /home/alice/data/* | sort -u"
check "and can edit them" as_alice 'echo x >>data/by-1000'

section "Pods"
check "the pod example (from the note)" as_alice "$(block Pods 1)"
check_output "podman pod ps lists it" 'mypod +Running' as_alice 'podman pod ps'
check_output "the published port reaches the pod" 'Welcome to nginx' curl -s http://127.0.0.1:8080/
check_output "containers in a pod share the network: 127.0.0.1 reaches nginx" 'Welcome to nginx' \
  as_alice 'podman run --rm --pod mypod docker.io/library/alpine wget -qO- http://127.0.0.1:80/'

section "Kubernetes interop"
check "podman kube generate (from the note)" as_alice "$(block 'Kubernetes interop' 1)"
check_output "it writes a Pod manifest" '^kind: Pod$' cat /home/alice/mypod.yml
check_output "podman kube play fails while the pod exists (as the note says)" 'already exists' \
  as_alice "$(block 'Kubernetes interop' 2) 2>&1; true"
check "--replace replaces it" as_alice 'podman kube play --replace mypod.yml'
check "the old names still work: generate kube" as_alice 'podman generate kube mypod >/dev/null'
check "and play kube" as_alice 'podman play kube --help >/dev/null'
as_alice 'podman pod rm -f mypod >/dev/null'

section "Running containers under systemd with Quadlet"
as_alice 'mkdir -p .config/containers/systemd'
block 'Quadlet' 1 | sed 's|ghcr.io/example/myapp:1.2.3|docker.io/library/nginx:alpine|' >/home/alice/.config/containers/systemd/myapp.container
chown alice: /home/alice/.config/containers/systemd/myapp.container
check_output "the Quadlet generator accepts the file" 'ExecStart=/usr/bin/podman run' \
  as_alice '/usr/lib/systemd/user-generators/podman-user-generator --dryrun 2>&1'
check_fails "without ~/myapp-data, the service does not start" as_alice "$(block 'Quadlet' 2 | grep -v '^mkdir')"
as_alice 'mkdir -p myapp-data && systemctl --user reset-failed myapp'
check "with the directory, it does (from the note)" as_alice "$(block 'Quadlet' 2)"
check "the container answers" retry 30 curl -sf -o /dev/null http://127.0.0.1:8080/
check_output "WantedBy=default.target: it starts with alice's systemd" 'myapp.service' \
  as_alice 'systemctl --user list-dependencies default.target'
as_alice 'podman kill systemd-myapp' >/dev/null 2>&1
check "Restart=always restarts it after it is killed" retry 60 as_alice \
  '[ "$(systemctl --user show myapp -p NRestarts --value)" -ge 1 ] && systemctl --user is-active myapp'
printf '[Pod]\nPodName=stack\nPublishPort=8081:80\n' >/home/alice/.config/containers/systemd/stack.pod
printf '[Volume]\n' >/home/alice/.config/containers/systemd/data.volume
printf '[Network]\n' >/home/alice/.config/containers/systemd/net.network
printf '[Image]\nImage=docker.io/library/alpine\n' >/home/alice/.config/containers/systemd/alpine.image
chown alice: /home/alice/.config/containers/systemd/*
gen=$(as_alice '/usr/lib/systemd/user-generators/podman-user-generator --dryrun 2>&1')
for unit in stack-pod data-volume net-network alpine-image; do
  assert_match ".${unit##*-} files work too: $unit.service" "^---${unit}\\.service---\$" "$gen"
done
as_alice 'systemctl --user stop myapp'
as_alice 'podman create --name gs docker.io/library/alpine true >/dev/null'
check_output "podman generate systemd prints DEPRECATED (as the note says)" 'DEPRECATED' \
  as_alice 'podman generate systemd --name gs 2>&1 >/dev/null'

section "Compose"
check "the socket, and DOCKER_HOST (from the note)" \
  as_alice "$(block Compose 1 | grep -v 'compose up')"
check_output "the Docker API answers on the Podman socket" '^OK$' \
  as_alice 'curl -s --unix-socket $XDG_RUNTIME_DIR/podman/podman.sock http://d/_ping'
cat >/home/alice/compose.yaml <<'EOF'
services:
  web:
    image: docker.io/library/nginx:alpine
    ports: ["8082:80"]
EOF
chown alice: /home/alice/compose.yaml
check "docker compose up -d works against it (from the note)" \
  as_alice "export DOCKER_HOST=unix://\$XDG_RUNTIME_DIR/podman/podman.sock; $(block Compose 1 | grep 'compose up')"
check_output "and the service answers" 'Welcome to nginx' bash -c 'sleep 2; curl -s http://127.0.0.1:8082/'
