#!/usr/bin/env bash
# note: containers/docker.md
# env: compose
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"

NOTE=containers/docker
cleanup() {
  docker rm -f leap_ftw ticker it_test rand apache-test srv kcli >/dev/null 2>&1 || true
  docker network rm test >/dev/null 2>&1 || true
  docker rmi -f my-nginx apache >/dev/null 2>&1 || true
}
trap 'cleanup; _t_finish $?' EXIT
cleanup

section "Installation"
check_output "docker run hello-world (from the note)" 'Hello from Docker!' \
  bash -ec "$(note_block "$NOTE" Installation 3)"

section "Commands worth knowing"
check "docker image ls --all (from the note)" bash -ec "$(note_block "$NOTE" 'Commands worth knowing' 1)"
check "the container ls variants (from the note)" bash -ec "$(note_block "$NOTE" 'Commands worth knowing' 2)"
retry 3 docker pull -q opensuse/leap:16 >/dev/null
check_output "docker inspect an image (from the note)" 'opensuse' \
  bash -ec "$(note_block "$NOTE" 'Commands worth knowing' 3)"
check "docker version and docker info (from the note)" bash -ec "$(note_block "$NOTE" 'Commands worth knowing' 4)"

# A named, long-running container for the commands that need one.
docker run -d --name leap_ftw opensuse/leap:16 sleep 600 >/dev/null
check_output "docker logs on a container (from the note)" '.*' docker logs leap_ftw
check_output "docker exec runs a command in a running container" '[0-9]' \
  docker exec leap_ftw date
check_fails "the callout is right: exec against a stopped container fails" \
  bash -c 'docker run --name it_test opensuse/leap:16 true && docker exec it_test uptime'
check_output "-it allocates a pseudo-terminal (via script)" 'is a tty' \
  script -qec "docker run --rm -it opensuse/leap:16 /bin/bash -c 'tty >/dev/null && echo is a tty'" /dev/null

docker run -d --name ticker busybox:1.37 sh -c 'while true; do echo tick; sleep 1; done' >/dev/null
docker stop ticker >/dev/null
check "docker start restarts a stopped container" docker start ticker
check_output "docker attach streams its output" 'tick' \
  bash -c 'timeout -k 2 5 docker attach --no-stdin ticker; true'

check "docker pause freezes with the cgroup freezer" docker pause leap_ftw
assert_eq "the container shows as paused" 'true' "$(docker inspect -f '{{.State.Paused}}' leap_ftw)"
check_fails "a paused container refuses exec" docker exec leap_ftw true
check "docker unpause" docker unpause leap_ftw

check "docker commit saves the container as an image (from the note)" \
  bash -ec "$(note_block "$NOTE" 'Commands worth knowing' 11)"
check_output "the committed image exists" 'my-nginx' docker image ls my-nginx

check "docker run -d -p 8080:80 nginx (from the note)" \
  bash -ec "$(note_block "$NOTE" 'Commands worth knowing' 12)"
check "the published port answers on localhost:8080" wait_http http://localhost:8080 60
docker rm -f "$(docker ps -q --filter ancestor=nginx | head -1)" >/dev/null

check_output "the correction is right: -p 80 alone publishes a random host port" \
  ':[0-9]+' bash -c 'docker run -d --name rand -p 80 nginx >/dev/null && docker port rand 80'
docker rm -f rand >/dev/null

docker stop leap_ftw >/dev/null   # the note removes a stopped container
check "docker rm removes the named container (from the note)" \
  bash -ec "$(note_block "$NOTE" 'Commands worth knowing' 13 | sed -n 1p)"
skip "docker rm \$(docker ps -aq) / docker rmi \$(docker images -q)" \
  "would remove every container and image on the shared host Docker"
check "docker system df works (from the correction)" docker system df
skip "docker system prune -a" "would remove other tests' cached images on the shared host"

section "Networks"
check_output "docker network ls shows bridge, host and none" 'bridge.*host.*none' \
  bash -c 'docker network ls --format "{{.Name}}" | sort | tr "\n" " "'
check "create a user-defined bridge (from the note)" bash -ec "$(note_block "$NOTE" Networks 2)"
docker run -d --name srv --network test nginx >/dev/null
check_output "user-defined bridges give DNS: reach a container by name" 'Welcome to nginx' \
  docker run --rm --network test busybox:1.37 wget -qO- -T 10 http://srv
docker rm -f srv >/dev/null
check "remove the network (from the note)" bash -ec "$(note_block "$NOTE" Networks 3)"
check_output "host mode shares the host's network namespace (sees docker0)" 'docker0' \
  docker run --rm --network host busybox:1.37 ip -o link
check_output "none mode leaves only loopback" '^1: lo' \
  docker run --rm --network none busybox:1.37 ip -o link
# kernels with tunnel modules add noop tunl0/gre0/... devices to every netns;
# "only loopback" means: no eth0, nothing but lo is usable.
assert_no_match "none mode has no ethernet interface" 'eth0' \
  "$(docker run --rm --network none busybox:1.37 ip -o link)"

section "Dockerfile"
WORK=$(mktemp -d) && cd "$WORK"
# shellcheck disable=SC2094 # "Dockerfile" is the heading to search, not the file written
note_block "$NOTE" Dockerfile 1 >Dockerfile
check "docker build -t apache . (from the note)" bash -ec "$(note_block "$NOTE" Dockerfile 2)"
docker run -d --name apache-test -p 18080:80 apache >/dev/null
check_output "the CMD serves: apache answers on the published port" 'It works' \
  curl -s --retry 30 --retry-all-errors --retry-delay 2 http://localhost:18080

section "Complementary tooling: hadolint"
printf 'MAINTAINER nobody\nFROM opensuse/leap:16.0\n' >Dockerfile.broken
check_fails "hadolint rejects the original's MAINTAINER-before-FROM" \
  bash -c 'docker run --rm -i hadolint/hadolint < Dockerfile.broken'
check "hadolint finds nothing error-level in the note's Dockerfile" \
  bash -c 'docker run --rm -i hadolint/hadolint hadolint --failure-threshold error - < Dockerfile'
