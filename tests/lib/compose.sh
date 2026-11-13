# shellcheck shell=bash
# Helpers for tests with `# env: compose`. These run on the host (in the runner
# container), one at a time, with Docker Compose. The runner exports
# COMPOSE_PROJECT_NAME, so a note's plain `docker compose up -d` gets a private project,
# and removes that project with its volumes after the test. Published ports answer on
# localhost, as the notes say, because the runner uses the host network.

: "${COMPOSE_PROJECT_NAME:?COMPOSE_PROJECT_NAME is set by scripts/test-notes.sh}"

# wait_http URL [TIMEOUT] [CURL_ARG...]: poll URL until it answers 2xx, or fail.
wait_http() {
  local url=$1 timeout=${2:-60} i
  shift 2 || shift $#
  for ((i = 0; i < timeout; i++)); do
    curl -fsS -o /dev/null "$@" "$url" 2>/dev/null && return 0
    sleep 1
  done
  echo "wait_http: $url did not answer in ${timeout}s" >&2
  return 1
}

# compose_logs SERVICE: the service's logs, to print when a check fails.
compose_logs() { docker compose logs --no-color "$1" 2>&1 | tail -50; }
