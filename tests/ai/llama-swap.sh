#!/usr/bin/env bash
# note: ai/llama-swap.md
# env: leap
# timeout: 900
# The note's backends (llama-server, mlx_lm.server) are swapped for a tiny fake
# OpenAI server that reports its port and the model name it received. llama-swap is
# the Linux release binary; brew and launchd are macOS-only and not run.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=ai/llama-swap
mkdir -p /work/ls && cd /work/ls
arch=$(uname -m); arch=${arch/x86_64/amd64}; arch=${arch/aarch64/arm64}
curl -sfL "https://github.com/mostlygeek/llama-swap/releases/download/v$LLAMA_SWAP_VERSION/llama-swap_${LLAMA_SWAP_VERSION}_linux_$arch.tar.gz" | tar xz -C /usr/local/bin llama-swap
cat >/work/fake.py <<'EOF'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port = int(sys.argv[sys.argv.index('--port') + 1])
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, body):
        data = json.dumps(body).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self): self.reply({'status': 'ok'})
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.reply({'object': 'chat.completion', 'choices': [{'message': {'role': 'assistant',
                    'content': 'port=%d model=%s pid=%d' % (port, req.get('model'), os.getpid())}}]})
HTTPServer(('127.0.0.1', port), H).serve_forever()
EOF
# The note's config, with the backends pointed at the fake server.
fake() { sed 's|^\( *\)llama-server --port|\1/usr/bin/python3 /work/fake.py --port|; s|^\( *\)mlx_lm.server --port|\1/usr/bin/python3 /work/fake.py --port|; s|YOUR_USER|ls|g'; }
ask() { curl -s -m 60 "http://localhost:${2:-8080}/v1/chat/completions" -H 'Content-Type: application/json' \
  -d "{\"model\": \"$1\", \"messages\": [{\"role\": \"user\", \"content\": \"hi\"}]}" | sed -n 's/.*"content": *"\([^"]*\)".*/\1/p'; }
up() { for _ in $(seq 30); do curl -sf "http://localhost:${1:-8080}/v1/models" >/dev/null && return 0; sleep 1; done; return 1; }
start() { llama-swap --config "$1" --listen "localhost:${2:-8080}" >"/tmp/ls-${2:-8080}.log" 2>&1 & up "${2:-8080}"; }
# By name: start may run inside check's subshell, where %1 is not this shell's job.
stop() { pkill -x llama-swap || true; pkill -f fake.py || true; sleep 1; }

section "Installation"
check_output "llama-swap --version (from the note, the Linux release binary)" "$LLAMA_SWAP_VERSION" bash -c 'llama-swap --version 2>&1'
skip "brew tap, brew install, brew trust" "Homebrew on macOS"

section "Configuration"
note_block "$NOTE" Configuration 1 | fake >~/llama-swap.yaml
check "the note's config loads (from the note, fake backends)" start ~/llama-swap.yaml
models=$(curl -s localhost:8080/v1/models)
for m in qwen-27b qwen-27b-mlx qwen-9b gemma4; do
  assert_match "/v1/models lists $m" "\"id\": *\"$m\"" "$models"
done
check_output "a request for qwen-27b starts its backend" '^port=58[0-9]{2} model=qwen-27b ' ask qwen-27b
check_output "useModelName rewrites the model sent upstream (the tip)" '^port=58[0-9]{2} model=/Users/ls/models/Qwen3\.6-27B-UD-MLX-4bit ' ask qwen-27b-mlx
check_output "  without it, the alias goes upstream as is" '^port=58[0-9]{2} model=qwen-9b ' ask qwen-9b
ports=$(for m in gemma4 qwen-27b qwen-27b-mlx qwen-9b; do printf '%s=%s ' "$m" "$(ask $m | sed 's/^port=\([0-9]*\).*/\1/')"; done)
check_output "startPort: ports are given in alphabetical order of model ID, from 5800 (the table)" \
  '^gemma4=5800 qwen-27b=5801 qwen-27b-mlx=5802 qwen-9b=5803 $' echo "$ports"
check_output "by default only one backend runs at a time" '^1$' bash -c "pgrep -fc '[p]ython3 /work/fake.py'"
stop

sed 's/^globalTTL: 600 .*/globalTTL: 3/' ~/llama-swap.yaml >ttl.yaml
start ttl.yaml
ask qwen-9b >/dev/null
check_output "globalTTL unloads an idle model (3 s here)" '"running": *\[\]' bash -c 'sleep 8; curl -s localhost:8080/running'
stop
printf 'globalTTL: 3\nmodels:\n  a:\n    cmd: /usr/bin/python3 /work/fake.py --port ${PORT}\n    ttl: 0\n  b:\n    cmd: /usr/bin/python3 /work/fake.py --port ${PORT}\n    ttl: -1\n' >ttl2.yaml
start ttl2.yaml
ask a >/dev/null
check_output "ttl: 0 never unloads (the table)" '"model": *"a"' bash -c 'sleep 8; curl -s localhost:8080/running'
stop

section "Absolute paths only"
for p in '~' '$HOME'; do
  printf 'models:\n  m:\n    cmd: /usr/bin/python3 %s/fake.py --port ${PORT}\n' "$p" >path.yaml
  cp /work/fake.py ~/fake.py
  start path.yaml 8090
  check_output "a $p path in cmd fails (the warning)" 'exited prematurely|upstream|error|502|503' \
    bash -c "curl -s localhost:8090/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"m\",\"messages\":[]}'; grep -i -m1 'exited\|error' /tmp/ls-8090.log"
  stop
done

section "Running it"
check "llama-swap --config ~/llama-swap.yaml --listen localhost:8080 (from the note)" \
  bash -c "$(note_block "$NOTE" 'Running it' 1) >/tmp/run.log 2>&1 & sleep 0; for i in \$(seq 30); do curl -sf localhost:8080/v1/models >/dev/null && exit 0; sleep 1; done; exit 1"
check_output "the built-in web UI answers on / (the note)" '^(200|30[1278])$' curl -s -o /dev/null -w '%{http_code}' localhost:8080/
stop

section "Model groups"
{ sed 's/^startPort: 5800 /startPort: 6800 /' ~/llama-swap.yaml; echo; note_block "$NOTE" 'Model groups' 1; } >groups.yaml
start groups.yaml
ask qwen-9b >/dev/null; ask qwen-27b >/dev/null; ask gemma4 >/dev/null
check_output "the note's top-level groups still load: qwen-9b stays while main swaps (2 backends)" '^2$' bash -c "pgrep -fc '[p]ython3 /work/fake.py'"
check_output "  the running one in main is gemma4, qwen-27b was swapped out" '^--port 68(00|03) --port 68(00|03) $' bash -c "pgrep -af '[p]ython3 /work/fake.py' | grep -o -- '--port [0-9]*' | tr '\n' ' '"
stop

section "Three configuration details"
check_output "llama.cpp turns Jinja on by default now, so --jinja is no longer needed (the tip, $LLAMA_CPP_VERSION source)" 'bool use_jinja = true;' \
  bash -c "curl -sf https://raw.githubusercontent.com/ggml-org/llama.cpp/$LLAMA_CPP_VERSION/common/common.h"

skip "launchd plist, launchctl" "macOS only"
skip "Zed, Open WebUI, Msty Claw, Pi clients" "GUI clients; they only need the /v1 URL checked above"
