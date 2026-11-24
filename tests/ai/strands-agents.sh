#!/usr/bin/env bash
# note: ai/strands-agents.md
# env: go
# timeout: 900
# The model is a scripted fake (fake.py), speaking both the OpenAI and the Ollama chat
# API: it calls the first tool it is offered once, then answers with the tool's result.
# So the test checks the agent loop and the tool schema, not a model's judgement.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=ai/strands-agents
export DEBIAN_FRONTEND=noninteractive AWS_EC2_METADATA_DISABLED=true
apt-get -qq update >/dev/null && apt-get -qq install -y python3-venv >/dev/null
python3 -m venv /opt/sa && export PATH=/opt/sa/bin:$PATH
mkdir -p /work/sa && cd /work/sa
block() { note_block "$NOTE" "$@"; }
cat >fake.py <<'EOF'
# fake.py PORT: /v1/chat/completions (OpenAI, streamed) and /api/chat (Ollama, ndjson).
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
ARGS = {"check_port": {"host": "127.0.0.1", "port": int(sys.argv[1])},
        "get_pod_status": {"namespace": "kube-system", "pod_name": "api-server"}}
def text(c): return c if isinstance(c, str) else " ".join(p.get("text", "") for p in c or [])
def plan(req):
    """(tool name, args) to call, or (None, answer text)."""
    msgs = req.get("messages", [])
    if msgs and msgs[-1].get("role") == "tool":
        return None, "RESULT: " + text(msgs[-1].get("content"))
    tools = [t["function"]["name"] for t in req.get("tools") or []]
    return (tools[0], ARGS.get(tools[0], {})) if tools else (None, "Paris")
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, ctype, chunks):
        self.send_response(200); self.send_header("Content-Type", ctype); self.end_headers()
        for c in chunks: self.wfile.write(c.encode()); self.wfile.flush()
    def do_GET(self): self.send("application/json", ['{"models": []}'])
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        open("/tmp/fake.jsonl", "a").write(json.dumps({"path": self.path, "req": req}) + "\n")
        name, arg = plan(req)
        if self.path.endswith("/chat/completions"):
            def chunk(delta, finish=None): return "data: " + json.dumps({"id": "c", "object": "chat.completion.chunk",
                "created": 0, "model": req.get("model"), "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}) + "\n\n"
            if name:
                out = [chunk({"role": "assistant", "tool_calls": [{"index": 0, "id": "call_1", "type": "function",
                       "function": {"name": name, "arguments": json.dumps(arg)}}]}), chunk({}, "tool_calls")]
            else:
                out = [chunk({"role": "assistant", "content": arg}), chunk({}, "stop")]
            usage = {"id": "c", "object": "chat.completion.chunk", "created": 0, "model": req.get("model"), "choices": [],
                     "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}
            self.send("text/event-stream", out + ["data: " + json.dumps(usage) + "\n\n", "data: [DONE]\n\n"])
        else:
            msg = {"role": "assistant", "content": "" if name else arg}
            if name: msg["tool_calls"] = [{"function": {"name": name, "arguments": arg}}]
            base = {"model": req.get("model"), "created_at": "2026-01-01T00:00:00Z"}
            last = dict(base, message={"role": "assistant", "content": ""}, done=True, done_reason="stop",
                        total_duration=1, load_duration=1, prompt_eval_count=1, prompt_eval_duration=1, eval_count=1, eval_duration=1)
            self.send("application/x-ndjson", [json.dumps(dict(base, message=msg, done=False)) + "\n", json.dumps(last) + "\n"])
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
python3 fake.py 8080 & python3 fake.py 11434 &
retry 20 curl -sf localhost:8080/ >/dev/null && retry 20 curl -sf localhost:11434/ >/dev/null

section "Installing"
check "pip install strands-agents strands-agents-tools (from the note, pinned)" \
  bash -c "$(block Installing 1 | sed "s/strands-agents /strands-agents==$STRANDS_VERSION /; s/strands-agents-tools\$/strands-agents-tools==$STRANDS_TOOLS_VERSION/") -q"
for m in ollama openai; do
  check_output "  that alone cannot load the $m provider: it is an extra (the correction)" "No module named '$m'" \
    bash -c "python3 -c 'import strands.models.$m' 2>&1; true"
done
check "pip install 'strands-agents[ollama,openai]' (from the note, pinned)" \
  bash -c "$(block Installing 2 | sed "s/]'/]==$STRANDS_VERSION'/") -q"

section "A minimal agent"
check_output "Agent() with no model is Amazon Bedrock (the note)" '^BedrockModel$' \
  python3 -c 'from strands import Agent; print(type(Agent().model).__name__)'
block 'A minimal agent' 1 >minimal.py
check_output "  so the minimal agent needs AWS credentials (the note)" 'NoCredentialsError|Unable to locate credentials' \
  bash -c 'timeout 120 python3 minimal.py 2>&1; true'

section "Tools"
# The tools block, with the OpenAI model from the note pointed at the fake.
{ block 'local model' 2; block Tools 1 | sed 's/^agent = Agent(tools=/agent = Agent(model=model, tools=/'; } >tools.py
grep -q 'Agent(model=model, tools=\[check_port\])' tools.py
spec=$(python3 -c 'exec(open("tools.py").read().split("\nagent = ")[0]); import json; print(json.dumps(check_port.tool_spec))')
assert_match "the docstring's first line is the tool description (the note)" '"description": "Check whether a TCP port is open on a host\.' "$spec"
assert_match "  Args: gives each parameter its description" '"host": \{[^}]*"description": "The hostname or IP address to check\."' "$spec"
assert_match "  the type hints give the types: port is an integer" '"port": \{[^}]*"type": "integer"' "$spec"
check_output "the agent calls check_port and answers with its result (fake model)" 'RESULT: .*127\.0\.0\.1:8080 is open' \
  bash -c 'timeout 120 python3 tools.py 2>&1'
check_output "  the tool schema reaches the model in the request" '"name": "check_port"' \
  bash -c "grep -m1 '/chat/completions' /tmp/fake.jsonl"

section "Pointing it at a local model"
{ block Tools 1 | sed '/^agent = /,$d'; block 'local model' 1 | sed '/^from strands import Agent$/d'; } >agent_ollama.py  # not ollama.py: that would hide the ollama package
check_output "OllamaModel at localhost:11434 (from the note, fake model)" 'RESULT: .*127\.0\.0\.1:11434 is open' \
  bash -c 'timeout 120 python3 agent_ollama.py 2>&1'
check_output "  it sends the model id from the note to /api/chat" '"model": "qwen3\.6:27b"' \
  bash -c "grep '/api/chat' /tmp/fake.jsonl | head -1"
check_output "OpenAIModel: model_id qwen-27b is the name sent (from the note)" '"model": "qwen-27b"' \
  bash -c "grep '/chat/completions' /tmp/fake.jsonl | head -1"

section "MCP"
# The server from ai/mcp, with a kubectl stub that prints its arguments.
note_block ai/mcp 'server in Python' 2 >k8s_mcp.py
printf '#!/bin/sh\necho "{\\"kind\\": \\"Pod\\", \\"args\\": \\"$*\\"}"\n' >/usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl
{ block 'local model' 2; block MCP 1 | sed 's/Agent(tools=/Agent(model=model, tools=/'; } >agent_mcp.py
check_output "MCPClient over stdio lists the server's tools and the agent calls one (from the note)" \
  'RESULT: .*get pod api-server -n kube-system -o json' bash -c 'timeout 180 python3 agent_mcp.py 2>&1'
check_output "  the MCP tool reached the model as get_pod_status" '"name": "get_pod_status"' \
  bash -c "grep get_pod_status /tmp/fake.jsonl | head -1"

skip "a real local model's tool calling (the warning)" "needs a 27B model; the fake only proves the loop"
skip "TypeScript SDK, Bedrock, AgentCore" "the note only names them"
