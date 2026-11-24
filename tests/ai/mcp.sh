#!/usr/bin/env bash
# note: ai/mcp.md
# env: go
# timeout: 1200
# Each server is driven with raw JSON-RPC over stdio (rpc.py below), so no client
# SDK is involved. kubectl is a stub that prints a pod. Zed is not run.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=ai/mcp
export DEBIAN_FRONTEND=noninteractive GOFLAGS=-mod=mod
apt-get -qq update >/dev/null && apt-get -qq install -y python3-venv nodejs npm git >/dev/null
python3 -m venv /opt/mcp && export PATH=/opt/mcp/bin:$PATH
mkdir -p /work/mcp && cd /work/mcp
printf '#!/bin/sh\necho "{\\"kind\\": \\"Pod\\", \\"args\\": \\"$*\\"}"\n' >/usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl
cat >rpc.py <<'EOF'
# rpc.py CMD...: initialize, then send each JSON request from stdin; print each reply.
import json, subprocess, sys, select, time
p = subprocess.Popen(sys.argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def send(m):
    try: p.stdin.write(json.dumps(m) + "\n"); p.stdin.flush()
    except BrokenPipeError: print("SERVER EXITED"); sys.exit(0)
def recv(want, t=30):
    end = time.time() + t
    while time.time() < end:
        if select.select([p.stdout], [], [], 1)[0]:
            line = p.stdout.readline()
            if not line: break
            try: m = json.loads(line)
            except ValueError: print("NOT JSON:", line.strip()); continue
            if m.get("id") == want: return m
    return {"error": "no reply"}
send({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18",
      "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}})
print(json.dumps(recv(0, 60)))
send({"jsonrpc": "2.0", "method": "notifications/initialized"})
for i, line in enumerate(sys.stdin, 1):
    req = json.loads(line); req.update(jsonrpc="2.0", id=i); send(req); print(json.dumps(recv(i)))
p.terminate()
EOF
rpc() { python3 rpc.py "$@"; }
LIST='{"method": "tools/list"}'

section "Writing a server in Python"
check "pip install \"mcp[cli]\" (from the note, pinned)" bash -c "$(note_block "$NOTE" 'server in Python' 1 | sed "s/\"mcp\\[cli\\]\"/\"mcp[cli]==$MCP_PY_VERSION\"/") -q"
check_output "the SDK needs Python 3.10 or later (the note)" '^>=3\.10' bash -c "pip show mcp >/dev/null && python3 -c 'import importlib.metadata as m; print(m.metadata(\"mcp\")[\"Requires-Python\"])'"
note_block "$NOTE" 'server in Python' 2 >k8s_mcp.py
out=$(rpc python3 k8s_mcp.py <<<"$LIST")
assert_match "the FastMCP server answers initialize (from the note)" '"serverInfo": \{"name": "k8s-tools"' "$out"
assert_match "  tools/list has get_pod_status" '"name": "get_pod_status"' "$out"
assert_match "  the docstring is the tool description (rule 3)" '"description": "Get the status of a Kubernetes pod."' "$out"
assert_match "  the type hints give the schema: namespace is a string (rule 2)" '"namespace": \{[^}]*"type": "string"' "$out"
out=$(rpc python3 k8s_mcp.py <<<'{"method": "tools/call", "params": {"name": "get_pod_status", "arguments": {"namespace": "dev", "pod_name": "web"}}}')
check_output "tools/call runs kubectl get pod web -n dev -o json" 'get pod web -n dev -o json' echo "$out"
{ note_block "$NOTE" 'server in Python' 2 | sed '/^if __name__/,$d'; note_block "$NOTE" 'server in Python' 3; printf '\nif __name__ == "__main__":\n    mcp.run(transport="stdio")\n'; } >k8s_res.py
out=$(rpc python3 k8s_res.py <<<'{"method": "resources/read", "params": {"uri": "config://cluster-info"}}')
check_output "the resource is readable at config://cluster-info (from the note)" '"uri": "config://cluster-info"' echo "$out"
sed 's/^mcp = MCPServer("k8s-tools")/mcp = MCPServer("k8s-tools")\nprint("starting")/' k8s_mcp.py >noisy.py
grep -q '^print("starting")' noisy.py
# Unbuffered, so the stray line reaches the pipe at once instead of at some later flush.
check_output "a print() writes a non-JSON line to the protocol stream (rule 1)" 'NOT JSON: starting' bash -c "PYTHONUNBUFFERED=1 python3 rpc.py python3 noisy.py <<<'$LIST'"
sed 's/def get_pod_status(namespace: str, pod_name: str) -> str:/def get_pod_status(namespace, pod_name):/' k8s_mcp.py >nohints.py
out=$(rpc python3 nohints.py <<<"$LIST")
assert_match "without type hints the tool is still listed" '"name": "get_pod_status"' "$out"
assert_match "  and each parameter becomes a plain string (rule 2, corrected)" '"namespace": \{"title": "namespace", "type": "string"\}' "$out"
check_output "a bare tools/list, without initialize, gets no tool list (Testing and debugging)" '^$|error|Invalid|initializ' \
  bash -c "$(note_block "$NOTE" 'Testing and debugging' 2 | sed 's/| python /| timeout 5 python3 /') 2>&1 | grep -v '\"tools\"' | head -3; true"
# Not http.py: that name would hide Python's own http module.
sed 's/mcp.run(transport="stdio")/mcp.run(transport="streamable-http")/' k8s_mcp.py >k8s_http.py
python3 k8s_http.py >/tmp/http.log 2>&1 &
check_output "transport=\"streamable-http\" serves /mcp (Transports)" 'k8s-tools' bash -c \
  'for i in $(seq 20); do curl -s -X POST localhost:8000/mcp -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
   -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}" && exit 0; sleep 1; done'
grep -i -m5 'uvicorn\|running on\|error\|http' /tmp/http.log | sed 's/^/# http.py: /'
pkill -f k8s_http.py || true

section "Writing a server in Go"
for i in 1 2; do
  sdk=$([ $i = 1 ] && echo "github.com/modelcontextprotocol/go-sdk@$MCP_GO_SDK_VERSION" || echo "github.com/mark3labs/mcp-go@$MCP_GO_VERSION")
  mkdir -p go$i && note_block "$NOTE" 'server in Go' $((i * 2)) >go$i/main.go
  check "example $i builds (from the note, $sdk)" bash -c "cd go$i && go mod init k8s-mcp >/dev/null 2>&1 && go get $sdk >/dev/null 2>&1 && $(note_block "$NOTE" 'server in Go' 5 2>/dev/null || echo 'go build -o k8s-mcp-server .')"
  out=$(rpc go$i/k8s-mcp-server <<<"$LIST")
  assert_match "  it lists get_pod_status with both arguments required" '"required": \["namespace", "pod_name"\]' "$out"
  out=$(rpc go$i/k8s-mcp-server <<<'{"method": "tools/call", "params": {"name": "get_pod_status", "arguments": {"namespace": "dev", "pod_name": "web"}}}')
  assert_match "  tools/call runs kubectl" 'get pod web -n dev -o json' "$out"
done
mkdir -p goold && cd goold && go mod init x >/dev/null 2>&1
check_output "the original go get .../go-sdk/server fails: there is no such package (the correction)" 'does not contain package github.com/modelcontextprotocol/go-sdk/server' \
  bash -c "go get github.com/modelcontextprotocol/go-sdk/server@$MCP_GO_SDK_VERSION 2>&1; true"
cd /work/mcp
sed 's/req.GetArguments()\["\([a-z_]*\)"\]/req.Params.Arguments["\1"]/' go2/main.go >goold/main.go
check_output "  and req.Params.Arguments[...] does not compile with mcp-go (the correction)" 'cannot index req.Params.Arguments' \
  bash -c "cd goold && go get github.com/mark3labs/mcp-go@$MCP_GO_VERSION >/dev/null 2>&1 && go build . 2>&1; true"

section "Using existing servers in Zed"
check_output "Debian's Node.js 20 cannot run server-filesystem: it needs Node 24 (the correction)" 'getSystemErrorMessage' \
  bash -c 'timeout 60 npx -y @modelcontextprotocol/server-filesystem /tmp 2>&1 </dev/null; true'
arch=$(uname -m); arch=${arch/x86_64/x64}; arch=${arch/aarch64/arm64}
curl -sfL "https://nodejs.org/dist/$NODEJS_VERSION/node-$NODEJS_VERSION-linux-$arch.tar.xz" | tar xJ -C /opt
export PATH=/opt/node-$NODEJS_VERSION-linux-$arch/bin:$PATH
check_output "  with Node $NODEJS_VERSION" '^v24\.' node --version
mkdir -p /tmp/project && echo hello >/tmp/project/a.txt
fs=$(note_block "$NOTE" 'existing servers' 1 | python3 -c 'import json,sys; c=json.load(sys.stdin)["context_servers"]["filesystem"]; print(c["command"], " ".join(c["args"]))')
read -ra FS <<<"${fs/\/path\/to\/project//tmp/project}"   # the command and its arguments, as words
out=$(rpc "${FS[@]}" <<<"$LIST")
assert_match "the filesystem server from the note starts and lists tools" '"name": "read_text_file"|"name": "read_file"' "$out"
out=$(rpc "${FS[@]}" <<<'{"method": "tools/call", "params": {"name": "list_directory", "arguments": {"path": "/tmp/project"}}}')
assert_match "  it reads the allowed directory" 'a\.txt' "$out"
out=$(rpc "${FS[@]}" <<<'{"method": "tools/call", "params": {"name": "list_directory", "arguments": {"path": "/etc"}}}')
assert_match "  and refuses paths outside it (the warning: scope it)" 'denied|outside|not allowed' "$out"
check "pip install uv, for uvx" pip install -q uv
git init -q /tmp/repo && git -C /tmp/repo -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
gitcmd=$(note_block "$NOTE" 'existing servers' 1 | python3 -c 'import json,sys; c=json.load(sys.stdin)["context_servers"]["git"]; print(c["command"], " ".join(c["args"]))')
read -ra GIT <<<"${gitcmd/\/path\/to\/repo//tmp/repo}"
out=$(rpc "${GIT[@]}" <<<"$LIST")
for t in git_log git_diff git_status git_commit; do
  assert_match "uvx mcp-server-git (from the note) has $t" "\"name\": \"$t\"" "$out"
done
for p in server-git server-postgres server-brave-search; do
  check_output "@modelcontextprotocol/$p on npm (the correction)" 'E404|Archived|no longer supported|deprecated' \
    bash -c "npm view @modelcontextprotocol/$p deprecated 2>&1; true"
done

skip "Zed settings, the agent panel and mcp-remote" "Zed is a desktop editor"
skip "npx @modelcontextprotocol/inspector" "a web UI"
