#!/usr/bin/env bash
# note: containers/docker.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"

# The install section cannot run in a container (no systemd, no host daemon), but the
# packaging claims it makes about Leap 16 can be checked against the repositories.

section "Installation on openSUSE Leap"
check_output "the docker package exists in the Leap repositories" 'docker' \
  zypper -n info docker
check_output "docker-buildx exists too (the note installs both)" 'docker-buildx' \
  zypper -n info docker-buildx
check_output "no docker-ce package: Docker Inc. ships no openSUSE repository" \
  'not found' bash -c 'zypper -n info docker-ce 2>&1; true'
check_output "no containerd.io package either" 'not found' \
  bash -c 'zypper -n info containerd.io 2>&1; true'

section "Compose is a plugin, not a standalone binary"
zypper -n -q install --no-recommends docker-compose >/dev/null
check "the docker-compose package ships the CLI plugin" \
  test -x /usr/lib/docker/cli-plugins/docker-compose
check_fails "and puts no docker-compose binary in \$PATH" command -v docker-compose
