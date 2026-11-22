#!/usr/bin/env bash
# note: kubernetes/workloads/kubectlproxy.md
# env: kind
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/workloads/kubectlproxy
cd "$(mktemp -d)"
# Tests share the host network: never assume 8001 is free. Every proxy is killed on exit.
free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
pids=()
# Same as _k8s_exit (lib/k8s.sh), with the proxies stopped first; keeps the test's status.
cleanup() {
  local rc=$? p
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  _k8s_stop_cpk
  _k8s_cleanup
  _t_finish "$rc"
}
trap '_k8s_rc=$?; cleanup' EXIT
# start_proxy PORT ARGS...: start kubectl proxy and wait until it answers.
start_proxy() {
  local port=$1
  shift
  kubectl proxy --port="$port" "$@" >/dev/null 2>&1 &
  pids+=($!)
  retry 20 curl -s "http://127.0.0.1:$port/version"
}
server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
apiserver=kube-apiserver-$CLUSTER-control-plane

section "Accessing the API with kubectl proxy"
check_fails "the API server has no --basic-auth-file option any more" \
  bash -c "kubectl -n kube-system exec $apiserver -- kube-apiserver --help | grep -q basic-auth-file"
for path in version healthz livez readyz; do
  check_output "system:anonymous can read /$path" '^200$' curl -sk -o /dev/null -w '%{http_code}' "$server/$path"
done
check_output "and cluster-info, on kubeadm clusters" '"name": "cluster-info"' \
  curl -sk "$server/api/v1/namespaces/kube-public/configmaps/cluster-info"
check_output "but nothing else" '^403$' curl -sk -o /dev/null -w '%{http_code}' "$server/api/v1/namespaces/default/configmaps"

section "Accessing the API directly"
check_output "kubectl get svc kubernetes (from the note)" '^kubernetes +ClusterIP +10\.96\.0\.1 ' \
  bash -ec "$(note_block "$NOTE" 'Accessing the API directly' 1) -n default"
check_output "anonymous curl: system:anonymous cannot get path / (the note's command, against the API address)" \
  'forbidden: User \\"system:anonymous\\" cannot get path \\"/\\"' \
  bash -ec "$(note_block "$NOTE" 'Accessing the API directly' 2 | sed "s#https://10.96.0.1#$server#")"

section "Authenticating to the API"
kubectl config view --minify --raw -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d >cert.pem
kubectl config view --minify --raw -o jsonpath='{.users[0].user.client-key-data}' | base64 -d >key.pem
check_output "the kubeconfig's key and certificate are PEM, in base64" '^-----BEGIN CERTIFICATE-----' head -1 cert.pem
check_output "with them, curl is authenticated" '"kind": "NamespaceList"' curl -sk --cert cert.pem --key key.pem "$server/api/v1/namespaces"

section "Trying kubectl proxy"
port=$(free_port)
script=$(note_block "$NOTE" 'Trying `kubectl proxy`' 1; echo 'sleep 2'
  note_block "$NOTE" 'Trying `kubectl proxy`' 2; note_block "$NOTE" 'Trying `kubectl proxy`' 3)
out=$(bash -c "$(sed -e "s/kubectl proxy &/kubectl proxy --port=$port \&/" -e "s/localhost:8001/localhost:$port/" <<<"$script")" 2>&1)
assert_match "start, curl, kill (from the note, on a free port): a list of API paths" '"paths": \[' "$out"
assert_match "it includes /api and /apis" '"/apis",' "$out"
check_fails "kill %1 stopped the proxy" curl -s --max-time 2 "http://127.0.0.1:$port/"

section "OpenAPI (fka Swagger)"
port=$(free_port)
start_proxy "$port"
check_output "the OpenAPI v2 specification is at /openapi/v2" '"swagger": ?"2\.0"' bash -c "curl -s http://127.0.0.1:$port/openapi/v2 | head -c 200"
check_output "v3, per API group, under /openapi/v3" '"apis/apps/v1"' curl -s "http://127.0.0.1:$port/openapi/v3"

section "kubectl proxy is intended for local use"
help=$(kubectl proxy --help)
assert_match "the default port is 8001" '-p, --port=8001:' "$help"
assert_match "the default address is 127.0.0.1" "--address='127.0.0.1'" "$help"
assert_match "the default accepted hosts" "--accept-hosts='\^localhost\\$,\^127\\\\\.0\\\\\.0\\\\\.1\\$,\^\\\\\[::1\\\\\]\\$'" "$help"
check_output "the proxy binds to 127.0.0.1" "127\.0\.0\.1:$port " ss -ltn
check_output "a request with another Host header is refused" '^403$' \
  curl -s -o /dev/null -w '%{http_code}' -H 'Host: proxy.example.com' "http://127.0.0.1:$port/version"
p0=$(mktemp)
kubectl proxy --port=0 >"$p0" 2>&1 &
pids+=($!)
retry 20 grep -q 'Starting to serve' "$p0" || true
check_output "--port=0 picks a free port" '^Starting to serve on 127\.0\.0\.1:[0-9]+$' cat "$p0"

section "Running kubectl proxy on a remote machine"
cmd=$(note_block "$NOTE" 'remote machine' 1)
help=$(kubectl proxy --help)
for flag in --port --address --accept-hosts; do
  assert_match "the note's $flag flag exists" "^ +(-p, )?$flag=" "$help"
done
skip "the note's remote proxy command: $cmd" "it would open unauthenticated cluster access on the shared host network; only its Host check is tested below, on 127.0.0.1"
port=$(free_port)
start_proxy "$port" --accept-hosts='.*'
check_output "--accept-hosts=.* accepts any Host header" '"major"' \
  curl -s -H 'Host: proxy.example.com' "http://127.0.0.1:$port/version"
kill "${pids[-1]}" 2>/dev/null || true

section "Good to know ..."
kubectl create deployment web --image=ghcr.io/jpetazzo/color >/dev/null
kubectl expose deployment web --port=80 >/dev/null
kubectl rollout status deploy/web --timeout=120s >/dev/null
port=$(free_port)
start_proxy "$port"
path=$(note_block "$NOTE" 'Good to know' 1 | sed -e "s/<namespace>/$TEST_NS/" -e 's/<service>/web/')
check_output "a Service through /api/v1/namespaces/NS/services/NAME/proxy (from the note)" 'This is pod' \
  curl -s "http://127.0.0.1:$port$path/"
pf=$(free_port)
kubectl port-forward svc/web "$pf:80" >/dev/null 2>&1 &
pids+=($!)
retry 20 curl -s "http://127.0.0.1:$pf/" || true
check_output "kubectl port-forward works for the same Service" 'This is pod' curl -s "http://127.0.0.1:$pf/"
