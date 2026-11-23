#!/usr/bin/env bash
# note: ai/pi.md
# env: go
# timeout: 900
# Pi runs in print mode (pi -p) against a fake OpenAI server that logs each request,
# so the test reads what Pi sends. No real model, no TUI keys (Ctrl+L, /tree, /share).
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=ai/pi
block() { note_block "$NOTE" "$@"; }
DEBIAN_FRONTEND=noninteractive apt-get -qq update >/dev/null && apt-get -qq install -y xz-utils >/dev/null
arch=$(uname -m); arch=${arch/x86_64/x64}; arch=${arch/aarch64/arm64}
curl -sfL "https://nodejs.org/dist/$NODEJS_VERSION/node-$NODEJS_VERSION-linux-$arch.tar.xz" | tar xJ -C /opt
export PATH=/opt/node-$NODEJS_VERSION-linux-$arch/bin:$PATH
mkdir -p /work/p/proj && cd /work/p/proj
cat >/work/fake.py <<'EOF'
# fake.py: an OpenAI chat server that answers "pong" and logs each request body.
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        body = json.dumps({"object": "list", "data": [{"id": "qwen-27b", "object": "model"}]}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        open("/tmp/req.jsonl", "a").write(json.dumps(req) + "\n")
        def chunk(delta, finish=None):
            return "data: " + json.dumps({"id": "c", "object": "chat.completion.chunk", "created": 0, "model": req.get("model"),
                                          "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}) + "\n\n"
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        for c in [chunk({"role": "assistant", "content": "pong"}), chunk({}, "stop"), "data: [DONE]\n\n"]:
            self.wfile.write(c.encode()); self.wfile.flush()
HTTPServer(("127.0.0.1", 8080), H).serve_forever()
EOF
python3 /work/fake.py &
retry 20 curl -sf localhost:8080/v1/models >/dev/null
last() { tail -1 /tmp/req.jsonl; }
export -f last
ask() { : >/tmp/req.jsonl; timeout 120 pi -p "${1:-ping}" </dev/null 2>&1; }

section "Installation"
check "npm install -g --ignore-scripts (from the note, pinned)" \
  bash -c "$(block Installation 1 | grep '^npm' | sed "s|pi-coding-agent\$|pi-coding-agent@$PI_VERSION|") >/dev/null 2>&1"
check_output "  pi --version" "$PI_VERSION" bash -c 'pi --version 2>&1'
check_output "it needs Node 22.19 or later (the note)" '>=22\.19' bash -c "npm view @earendil-works/pi-coding-agent@$PI_VERSION engines.node"
curl -fsSL https://pi.dev/install.sh -o install.sh
check_output "install.sh, read before running (the note): it installs the npm package" 'PI_PACKAGE="@earendil-works/pi-coding-agent"' cat install.sh

section "llama.cpp, MLX or llama-swap"
check "mkdir -p ~/.pi/agent (from the note)" bash -c "$(block 'llama-swap' 1)"
block 'llama-swap' 2 >~/.pi/agent/models.json
block 'llama-swap' 3 >~/.pi/agent/settings.json
check_output "pi -p answers through the models.json provider (Print mode)" 'pong' ask
req=$(last)
assert_match "  settings.json: defaultModel qwen-27b is the model sent" '"model": "qwen-27b"' "$req"
assert_no_match "  compat: no developer role" '"role": "developer"' "$req"
assert_no_match "  compat: no reasoning_effort" 'reasoning_effort' "$req"
assert_no_match "  compat: no usage in streaming" 'include_usage' "$req"
assert_no_match "  compat: max_completion_tokens is not used" 'max_completion_tokens' "$req"
python3 - <<'EOF'
import json, os
p = os.path.expanduser("~/.pi/agent/models.json")
c = json.load(open(p)); del c["providers"]["llama-swap"]["compat"]; json.dump(c, open(p, "w"))
EOF
ask >/dev/null || true
check_output "without compat, Pi sends what local servers reject (the important callout)" 'developer|reasoning_effort|include_usage|max_completion_tokens' \
  bash -c "last | grep -o '\"role\": \"developer\"\\|reasoning_effort\\|include_usage\\|max_completion_tokens' | sort -u"
block 'llama-swap' 2 >~/.pi/agent/models.json

section "AGENTS.md"
echo 'MARK-GLOBAL' >~/.pi/agent/AGENTS.md
echo 'MARK-PARENT' >/work/p/AGENTS.md
echo 'MARK-CWD' >/work/p/proj/AGENTS.md
ask >/dev/null || true
sys=$(last | python3 -c 'import json,sys; m=json.load(sys.stdin)["messages"]; print(" ".join(x["content"] if isinstance(x["content"], str) else json.dumps(x["content"]) for x in m if x["role"] in ("system", "developer")))' | tr '\n' ' ')
check_output "Pi loads AGENTS.md from ~/.pi/agent, the parent and the current directory, in that order (the note)" \
  'MARK-GLOBAL.*MARK-PARENT.*MARK-CWD' echo "$sys"

section "Modes"
check_output "--mode json prints an event stream" '^\{.*"type"' bash -c 'timeout 120 pi --mode json -p ping </dev/null 2>&1 | head -3'

skip "Ollama native provider and /model" "interactive; the Ollama API itself is tested in ai/ollama"
skip "Ctrl+L, Ctrl+P, /tree, /share, /export, steering keys" "TUI only"
skip "llama-server and mlx_lm.server rejecting those fields" "only what Pi sends is checked, against a fake server"
