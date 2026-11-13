#!/bin/sh
# Run a command inside the runner image (tests/runner/Dockerfile), with the host Docker
# socket and host networking, so kind and k3d clusters and their published ports are
# reached as on a Linux host. Runs the command directly when already in the runner,
# in CI, in the devcontainer, or with RUNNER=native.
#
# POSIX sh on purpose: macOS still ships bash 3.2, which the test scripts do not support.
#
# Usage: scripts/runner.sh CMD [ARG...]
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

native() {
  [ "${RUNNER:-}" = native ] || [ -n "${NOTES_IN_RUNNER:-}" ] || [ -n "${CI:-}" ] ||
    [ -f /.dockerenv ] || [ -n "${REMOTE_CONTAINERS:-}" ] || [ -n "${CODESPACES:-}" ]
}

if native; then exec "$@"; fi

# A tag per tool set: a change to the pinned versions or the Dockerfile builds a new image.
tag=$(cat tests/versions.env tests/runner/Dockerfile scripts/install-test-tools.sh |
  { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-12)
IMAGE=notes-runner:$tag

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "building $IMAGE (once per tool version change)" >&2
  docker build -q -t "$IMAGE" -t notes-runner:latest \
    --build-context scripts=scripts --build-context tests=tests tests/runner >/dev/null
fi

# The repository is mounted at the same path as on the host: tests pass paths under it
# to `docker run -v`, and the host daemon resolves them on the host.
set -- -v "$ROOT:$ROOT" -w "$ROOT" "$IMAGE" "$@"
set -- -v /var/run/docker.sock:/var/run/docker.sock --network host "$@"
if [ "$(uname -s)" = Linux ]; then
  # Keep the host user as owner of files written in the repository.
  set -- --user "$(id -u):$(id -g)" --group-add "$(stat -c %g /var/run/docker.sock)" "$@"
fi
if [ -t 0 ] && [ -t 1 ]; then set -- -t "$@"; fi
# Pass the variables the scripts read, so `JOBS=8 task test` works through the runner.
exec docker run --rm -i -e CLUSTER -e KEEP_CLUSTER -e JOBS -e TERM "$@"
