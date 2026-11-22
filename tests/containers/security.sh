#!/usr/bin/env bash
# note: containers/security.md
# env: compose
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"

NOTE=containers/security
P=$COMPOSE_PROJECT_NAME
cleanup() {
  docker rm -f "$P-lim" "$P-res" "$P-user" "$P-hard" "$P-health" "$P-restart" "$P-app" "$P-logged" >/dev/null 2>&1 || true
  docker rmi -f "$P-appimg" "$P-healthimg" "$P-msb" >/dev/null 2>&1 || true
}
trap 'cleanup; _t_finish $?' EXIT
cleanup
WORK=$(mktemp -d) && cd "$WORK"

section "Resource exhaustion"
docker run -d --name "$P-lim" --pids-limit 100 --ulimit nproc=64:64 busybox:1.37 sleep 300 >/dev/null
assert_eq "--pids-limit lands in the container's pids.max" 100 \
  "$(docker exec "$P-lim" cat /sys/fs/cgroup/pids.max)"
check_output "--ulimit nproc is applied" 'Max processes +64 +64' \
  docker exec "$P-lim" cat /proc/1/limits
docker run -d --name "$P-res" --memory 512m --cpus 1.5 busybox:1.37 sleep 300 >/dev/null
assert_eq "--memory 512m lands in memory.max" 536870912 \
  "$(docker exec "$P-res" cat /sys/fs/cgroup/memory.max)"
assert_eq "--cpus 1.5 lands in cpu.max" "150000 100000" \
  "$(docker exec "$P-res" cat /sys/fs/cgroup/cpu.max)"

section "Do not run as root"
cat >Dockerfile <<EOF
FROM opensuse/leap:16.0
$(note_block "$NOTE" 'Do not run as root' 1)
CMD ["sleep", "300"]
EOF
docker build -q -t "$P-appimg" . >/dev/null
docker run -d --name "$P-app" "$P-appimg" >/dev/null
check_output "the USER directive applies to the running process" '^app$' \
  docker exec "$P-app" whoami
check_output "--user 1000:1000 at runtime" '^1000$' \
  docker run --rm --user 1000:1000 busybox:1.37 id -u
docker run -d --name "$P-hard" --read-only --tmpfs /tmp --cap-drop ALL \
  --security-opt no-new-privileges busybox:1.37 sleep 300 >/dev/null
check_fails "--read-only: writing to / fails" docker exec "$P-hard" touch /x
check "--tmpfs /tmp: writing to /tmp still works" docker exec "$P-hard" touch /tmp/x
assert_match "--cap-drop ALL: the effective capability set is empty" \
  'CapEff:\s+0+$' "$(docker exec "$P-hard" grep CapEff /proc/1/status)"
check_output "no-new-privileges is set on the process" '^NoNewPrivs:\s+1' \
  docker exec "$P-hard" grep NoNewPrivs /proc/1/status

section "Networking"
skip "icc: false in /etc/docker/daemon.json" \
  "daemon-wide setting on the shared host Docker; the per-network isolation it gives is tested in containers/docker"

section "Logging"
skip "log-driver syslog to a remote collector" "needs a reachable syslog endpoint; rsyslog reception is tested in linux/logging/rsyslog"
docker run -d --name "$P-logged" --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
  busybox:1.37 sh -c 'echo hello; sleep 60' >/dev/null
check_output "per-container log options are applied (max-size)" '10m' \
  docker inspect -f '{{ .HostConfig.LogConfig.Config }}' "$P-logged"
docker rm -f "$P-logged" >/dev/null

section "Healthchecks"
cat >Dockerfile.health <<'EOF'
FROM busybox:1.37
RUN mkdir -p /www && echo ok > /www/index.html
HEALTHCHECK --interval=2s --timeout=3s --retries=3 \
  CMD wget -q -O /dev/null http://localhost:8080/ || exit 1
CMD ["sh", "-c", "httpd -p 8080 -h /www && exec sleep 600"]
EOF
docker build -q -t "$P-healthimg" -f Dockerfile.health . >/dev/null
docker run -d --name "$P-health" "$P-healthimg" >/dev/null
check "the healthcheck turns the container healthy" retry 30 bash -c \
  "docker inspect -f '{{.State.Health.Status}}' $P-health | grep -qx healthy"
# "Docker only reports the status; it does not act on it": break the check, keep PID 1.
docker exec "$P-health" pkill httpd
check "an unhealthy container is reported, not restarted" retry 30 bash -c \
  "docker inspect -f '{{.State.Health.Status}} {{.State.Restarting}}' $P-health | grep -qx 'unhealthy false'"

section "Restart policy"
docker run -d --name "$P-restart" --restart on-failure:5 busybox:1.37 false >/dev/null
check "on-failure:5 stops retrying after 5 restarts" retry 60 bash -c \
  "[ \"\$(docker inspect -f '{{.RestartCount}} {{.State.Running}}' $P-restart)\" = '5 false' ]"

section "Image hygiene: multi-stage build"
mkdir -p cmd/app
cat >cmd/app/main.go <<'EOF'
package main

import "fmt"

func main() { fmt.Println("multi-stage ok") }
EOF
cat >go.mod <<'EOF'
module example.com/app

go 1.23
EOF
note_block "$NOTE" 'Multi-stage builds' 1 >Dockerfile.msb
check "the note's multi-stage Dockerfile builds" docker build -q -t "$P-msb" -f Dockerfile.msb .
check_output "only the binary is in the final image, and it runs" 'multi-stage ok' \
  docker run --rm "$P-msb"
check_output "the distroless image runs as nonroot" 'nonroot|65532' \
  docker inspect -f '{{.Config.User}}' "$P-msb"

section "Vulnerability scanning"
skip "trivy image / docker scout cves" \
  "scanner and CVE database downloads; image scanning is covered by security/supply-chain/sbom"

section "Pin by digest"
digest=$(docker inspect -f '{{index .RepoDigests 0}}' busybox:1.37 2>/dev/null || true)
[[ -n $digest ]] || { docker pull -q busybox:1.37 >/dev/null; digest=$(docker inspect -f '{{index .RepoDigests 0}}' busybox:1.37); }
printf 'FROM %s\n' "$digest" >Dockerfile.pin
check "a FROM pinned by digest builds" docker build -q -f Dockerfile.pin .
