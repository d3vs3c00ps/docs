#!/usr/bin/env bash
# note: kubernetes/concepts/internal-apis.md
# env: kind
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/concepts/internal-apis
NODE=$CLUSTER-control-plane
WORK=/tmp/$TEST_NS
cd "$(mktemp -d)"
# on_node CMD: run CMD in the control plane node, in a work dir that holds admin.crt/key.
# stderr is dropped: curl progress meters would land in the checked output.
on_node() { docker exec "$NODE" sh -c "cd $WORK && $1" 2>/dev/null; }
_cleanup_node() { docker exec "$NODE" rm -rf "$WORK" >/dev/null 2>&1 || true; }
_exit() { local rc=$?; _cleanup_node; (exit "$rc"); _k8s_exit; }
trap '_k8s_rc=$?; _exit' EXIT
docker exec "$NODE" mkdir -p "$WORK"

section "API hunting guide"
ports=$(on_node "$(note_block "$NOTE" 'API hunting guide' 1)")
for p in etcd:2379 etcd:2380 etcd:2381 kubelet:10248 kubelet:10250 kube-proxy:10249 kube-proxy:10256 \
  kube-controller:10257 kube-scheduler:10259; do
  assert_match "ss -ltnp shows ${p%%:*} on port ${p#*:} (from the note)" ":${p#*:} .*\"${p%%:*}\"" "$ports"
done
assert_no_match "the process name is cut to kube-controller" 'kube-controller-manager' "$ports"
assert_match "kubelet health listens on 127.0.0.1 only" '127\.0\.0\.1:10248 ' "$ports"

section "etcd"
check_output "/health answers health true (from the note)" '^\{"health":"true","reason":""\}$' on_node "$(note_block "$NOTE" etcd 1)"
check_output "/metrics on 2381, no authentication" '^etcd_server_has_leader 1' \
  on_node "curl -s http://127.0.0.1:2381/metrics | grep ^etcd_server_has_leader"
check_fails "2379 refuses a client with no certificate" on_node "curl -sk -m 5 https://127.0.0.1:2379/health"
check_output "2379 accepts an etcd client certificate (mTLS)" '"health":"true"' \
  on_node "curl -s --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/healthcheck-client.crt --key /etc/kubernetes/pki/etcd/healthcheck-client.key https://127.0.0.1:2379/health"
check_fails "2380 refuses a peer with no certificate" on_node "curl -sk -m 5 https://\$(hostname -i):2380/members"

section "kubelet"
check_output "10248/healthz returns ok (from the note)" '^ok$' on_node "$(note_block "$NOTE" kubelet 1)"
check_output "10250 without a certificate: Unauthorized" '^Unauthorized$' on_node "curl -sk https://127.0.0.1:10250/healthz"

section "Trying the kubelet API"
check "extract admin.crt and admin.key from the kubeconfig (from the note)" bash -ec "$(note_block "$NOTE" 'Trying the kubelet API' 1)"
check_output "it is the cluster admin certificate" 'CN *= *kubernetes-admin' openssl x509 -in admin.crt -noout -subject
docker exec -i "$NODE" sh -c "cat >$WORK/admin.crt" <admin.crt
docker exec -i "$NODE" sh -c "cat >$WORK/admin.key" <admin.key
pod=$(kubectl -n kube-system get pods -l k8s-app=kube-proxy --field-selector "spec.nodeName=$NODE" -o jsonpath='{.items[0].metadata.name}')
run=$(note_block "$NOTE" 'Trying the kubelet API' 2 | sed "s/kube-proxy-xy123/$pod/")
check_output "/run runs kube-proxy --version in the Pod (from the note)" '^Kubernetes v1\.[0-9]+' on_node "$run"
check_output "the old form, -d cmd=ls, runs an empty command" 'exec: "": executable file not found' \
  on_node "curl -sk --cert admin.crt --key admin.key -d cmd=ls https://localhost:10250/run/kube-system/$pod/kube-proxy"
check_output "and the kube-proxy image has no ls" 'exec: "ls": executable file not found' \
  on_node "curl -sk --cert admin.crt --key admin.key -X POST 'https://localhost:10250/run/kube-system/$pod/kube-proxy?cmd=ls'"

section "kubelet API"
k() { on_node "curl -sk --cert admin.crt --key admin.key 'https://127.0.0.1:10250/$1'"; }
check_output "/healthz" '^ok$' k healthz
check_output "/configz serves the kubelet configuration" '"kind":"KubeletConfiguration"' k configz
check_output "/metrics" '^# (HELP|TYPE) ' k metrics
check_output "/pods returns a PodList" '"kind":"PodList"' k pods
check_output "/runningpods/ returns a PodList" '"kind":"PodList"' k runningpods/
check_output "/logs/ serves /var/log" 'href="containers/"' k logs/
check_output "/containerLogs/<namespace>/<podname>/<containername>?tail=10" '.' k "containerLogs/kube-system/$pod/kube-proxy?tail=10"
proxy=$(note_block "$NOTE" 'kubelet API' 1 | sed "s/NODE/$NODE/")
check_output "the API server proxies /healthz (from the note)" '^ok$' bash -ec "$(sed -n 1p <<<"$proxy")"
check_output "and /configz (from the note)" '"kind":"KubeletConfiguration"' bash -ec "$(sed -n 2p <<<"$proxy")"

section "kube-proxy"
kp=$(note_block "$NOTE" kube-proxy 1)
check_output "10249/healthz returns ok (from the note)" '^ok$' on_node "$(sed -n 1p <<<"$kp")"
check_output "10256/healthz answers JSON with timestamps (from the note)" '"lastUpdated":"[0-9]{4}-' on_node "$(sed -n 2p <<<"$kp")"
check_output "10249/configz" '"kind":"KubeProxyConfiguration"' on_node "curl -s http://127.0.0.1:10249/configz"
check_output "10249/metrics" '^# (HELP|TYPE) ' on_node "curl -s http://127.0.0.1:10249/metrics | head -1"

section "kube-controller-manager and kube-scheduler"
cm=$(note_block "$NOTE" 'kube-controller-manager and kube-scheduler' 1)
check_output "10257/healthz needs no authentication (from the note)" '^ok$' on_node "$(sed -n 1p <<<"$cm")"
check_output "10257/metrics with the admin certificate (from the note)" '^# (HELP|TYPE) ' on_node "$(sed -n 2p <<<"$cm") | head -1"
check_output "without it: forbidden for system:anonymous" 'forbidden: User \\"system:anonymous\\"' \
  on_node "curl -sk https://127.0.0.1:10257/metrics"
check_output "10257/configz with the certificate" '"componentconfig"|KubeControllerManagerConfiguration' \
  on_node "curl -sk --cert admin.crt --key admin.key https://127.0.0.1:10257/configz"
check_output "10259/healthz, same routes for the scheduler" '^ok$' on_node "curl -sk https://127.0.0.1:10259/healthz"
check_output "10259/configz with the certificate" 'KubeSchedulerConfiguration' \
  on_node "curl -sk --cert admin.crt --key admin.key https://127.0.0.1:10259/configz"
check_output "10259/metrics without it: forbidden" 'system:anonymous' on_node "curl -sk https://127.0.0.1:10259/metrics"
