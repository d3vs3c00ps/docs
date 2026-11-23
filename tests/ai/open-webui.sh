#!/usr/bin/env bash
# note: ai/open-webui.md
# env: compose
# timeout: 1800
# The note's docker run, pinned, with its own name, volume and host port so it cannot
# touch a real instance. The backend is a fake OpenAI server on a private network.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=ai/open-webui
block() { note_block "$NOTE" "$@"; }
N=notes-owui-$COMPOSE_PROJECT_NAME PORT=3917 URL=http://localhost:3917
trap 'rc=$?; docker rm -f "$N" "$N-fake" >/dev/null 2>&1; docker volume rm -f "$N-data" >/dev/null 2>&1; docker network rm "$N-net" >/dev/null 2>&1; _t_finish "$rc"' EXIT
docker network create "$N-net" >/dev/null
docker run -d --name "$N-fake" --network "$N-net" mirror.gcr.io/library/python:3.12-slim python -c '
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        b = json.dumps({"object": "list", "data": [{"id": "qwen-27b", "object": "model"}, {"id": "qwen-9b", "object": "model"}]}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b)
HTTPServer(("0.0.0.0", 8080), H).serve_forever()' >/dev/null
# run [ENV...]: the note's command, renamed and pinned, on the private network.
run() {
  local e=() v; for v in "$@"; do e+=(-e "$v"); done
  block Docker 1 | sed "s|--name open-webui|--name $N --network $N-net ${e[*]}|; s|3000:8080|$PORT:8080|; s|-v open-webui:|-v $N-data:|; s|:main\$|:v$OPEN_WEBUI_VERSION|" | bash >/dev/null
}
signup() { curl -s "$URL/api/v1/auths/signup" -H 'Content-Type: application/json' \
  -d "{\"name\": \"$1\", \"email\": \"$1@example.com\", \"password\": \"Correct-Horse-9\"}"; }
token() { curl -s "$URL/api/v1/auths/signin" -H 'Content-Type: application/json' \
  -d "{\"email\": \"$1@example.com\", \"password\": \"Correct-Horse-9\"}" | jq -r .token; }
export URL
export -f signup

section "Docker"
check "docker run (from the note, pinned to v$OPEN_WEBUI_VERSION)" run "OPENAI_API_BASE_URL=http://$N-fake:8080/v1" OPENAI_API_KEY=none
check "it answers on the mapped port" wait_http "$URL/health" 600
check_output "  the restart policy is unless-stopped" '^unless-stopped$' docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$N"
check_output "it listens on 8080 inside the container (the warning)" '8080/tcp' docker port "$N"
check_fails "nothing in the image reads WEBUI_PORT (the correction): the image uses PORT" docker exec "$N" grep -rqs WEBUI_PORT /app/backend
check_output "  start.sh: PORT, default 8080" 'PORT="\$\{PORT:-8080\}"' docker exec "$N" grep -h 'PORT=' /app/backend/start.sh

section "Security"
check_output "the first account to register is an administrator (the danger callout)" '^admin$' bash -c 'signup alice | jq -r .role'
check_output "  and that closes sign-up: a second one is refused (the correction)" 'permission' bash -c 'signup bob | jq -r .detail'
# Restart with sign-up asked for: the value stored at the first sign-up wins.
docker rm -f "$N" >/dev/null && run ENABLE_SIGNUP=true "OPENAI_API_BASE_URL=http://$N-fake:8080/v1" OPENAI_API_KEY=none
wait_http "$URL/health" 600
check_output "ENABLE_SIGNUP=true on a restart does not reopen it: the stored setting wins (the correction)" 'permission' bash -c 'signup carol | jq -r .detail'
check_output "the data volume holds the database (the danger callout)" 'webui\.db' \
  docker run --rm -v "$N-data:/d:ro" mirror.gcr.io/library/busybox:1.37 ls /d

section "Connecting a local backend"
T=$(token alice)
check_output "OPENAI_API_BASE_URL: the backend's /v1/models appear in the picker (the table)" '"qwen-27b".*"qwen-9b"|"qwen-9b".*"qwen-27b"' \
  bash -c "curl -s -H 'Authorization: Bearer $T' $URL/api/models | jq -c '[.data[].id]'"
check_output "in Docker, the Ollama URL defaults to host.docker.internal:11434, not localhost" 'host\.docker\.internal:11434' \
  bash -c "curl -s -H 'Authorization: Bearer $T' $URL/ollama/config | jq -c .OLLAMA_BASE_URLS"
check_output "the troubleshooting curl, from the container's network" '"qwen-27b"' \
  docker run --rm --network "$N-net" mirror.gcr.io/library/busybox:1.37 wget -qO- "http://$N-fake:8080/v1/models"

section "Running at login"
check "docker update --restart unless-stopped (from the note)" bash -c "$(block 'Running at login' 1 | grep '^docker' | sed "s/ open-webui\$/ $N/")"

skip "brew install open-webui, open -a" "macOS; the Homebrew cask is checked to exist below"
check_output "the open-webui Homebrew cask exists" '^200$' curl -s -o /dev/null -w '%{http_code}' https://formulae.brew.sh/api/cask/open-webui.json
check_output "  but there is no formula, so brew services cannot start it (the correction)" '^404$' \
  curl -s -o /dev/null -w '%{http_code}' https://formulae.brew.sh/api/formula/open-webui.json
skip "pip install open-webui" "the PyPI package is checked for its Python range below"
check_output "pip: open-webui $OPEN_WEBUI_VERSION needs Python 3.11 or 3.12 (the correction)" '<3\.13.*>=3\.11|>=3\.11.*<3\.13' \
  bash -c "curl -sL https://pypi.org/pypi/open-webui/$OPEN_WEBUI_VERSION/json | jq -r .info.requires_python"
skip "documents, RAG, presets, pipelines" "UI features"
