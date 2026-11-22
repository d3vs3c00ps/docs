#!/usr/bin/env bash
# note: kubernetes/workloads/kubectlexpose.md
# env: kind
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/workloads/kubectlexpose
cd "$(mktemp -d)"
# Docker Hub limits anonymous pulls, and many tests share this machine's address: run the
# note's commands with the same image from its GitHub registry copy.
block() { note_block "$NOTE" "$@" | sed 's#--image=jpetazzo/color#--image=ghcr.io/jpetazzo/color#'; }
# The note's curl commands run "in a Pod" on kind: this one has curl.
kubectl run curl --image=quay.io/curl/curl --restart=Never --command -- sleep 900 >/dev/null
incluster() { kubectl exec curl -- sh -c "$*"; }
podname() { kubectl get pods -l app=blue --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'; }
podip() { kubectl get pod "$1" -o jsonpath='{.status.podIP}'; }

section "Heads up!"
arch=$(kubectl get node "$CLUSTER-worker" -o jsonpath='{.status.nodeInfo.architecture}')
skip "kubectl run --image=archlinux myshell" "interactive (-ti); archlinux is amd64 only (nodes here: $arch) and on rate-limited Docker Hub; a curl Pod stands in"
kubectl wait --for=condition=Ready pod/curl --timeout=120s >/dev/null

section "Running our HTTP server"
check "kubectl create deployment blue (from the note)" bash -ec "$(block 'Running our HTTP server' 1)"
check "its Pod starts" kubectl rollout status deploy/blue --timeout=120s

section "Connecting to the HTTP server"
check_output "kubectl get pods -o wide shows the Pod IP (from the note)" '^blue-.* 10\.244\.' bash -ec "$(block 'Connecting to the HTTP server' 1)"
pod=$(podname) ip=$(podip "$(podname)")
check_output "from a Pod, curl the Pod IP (from the note): it shows the Pod name" "This is pod $TEST_NS/$pod" \
  incluster "$(block 'Connecting to the HTTP server' 2 | sed "s/IP-ADDRESS/$ip/")"
check_fails "from outside the cluster, the Pod IP cannot be reached" curl -s --max-time 3 "http://$ip"

section "The Pod doesn't have a stable identity"
check "kubectl delete pod (from the note)" bash -ec "$(block "stable identity" 2 | sed "s/blue-xxxxxxxx-yyyyy/$pod/")"
kubectl rollout status deploy/blue --timeout=120s >/dev/null
retry 30 bash -c "[ -n \"\$(kubectl get pods -l app=blue --field-selector=status.phase=Running -o name)\" ]"
new=$(podname)
check "the replacement Pod has another name" test "$new" != "$pod"
check "and another IP address" test "$(podip "$new")" != "$ip"

section "Exposing our deployment"
check_output "kubectl expose deployment blue --port=80 (from the note)" '^service/blue exposed$' bash -ec "$(block 'Exposing our deployment' 1)"
check_output "kubectl get service shows its ClusterIP (from the note)" '^blue +ClusterIP +10\.96\.[0-9.]+ +<none> +80/TCP' bash -ec "$(block 'Exposing our deployment' 2)"

section "Services are layer 4 constructs"
check_output "with no port to find, kubectl expose fails" "couldn't find port" \
  bash -c 'kubectl expose deployment blue --name=noport --dry-run=client 2>&1; true'
check_output "a Service is an address + protocol + port" '^80/TCP$' kubectl get svc blue -o jsonpath='{.spec.ports[0].port}/{.spec.ports[0].protocol}'

section "Testing our service"
eval "$(block 'Testing our service' 1)"
check_output "the go-template gives the ClusterIP (from the note)" '^10\.96\.' echo "$CLUSTER_IP"
# kube-proxy programs a new Service within a few seconds.
retry 30 incluster "curl -sf -m1 http://$CLUSTER_IP" || true
check_output "10 requests through the Service (from the note)" '^10$' \
  incluster "CLUSTER_IP=$CLUSTER_IP; $(block 'Testing our service' 2) | grep -c 'This is pod'"

section "A stable endpoint"
loop=$(note_block "$NOTE" 'stable* endpoint' 1)
incluster "export CLUSTER_IP=$CLUSTER_IP; timeout 20 sh -c '$loop'" >requests.log 2>&1 &
sleep 4
old=$(podname)
check "kubectl delete pod while requests run (from the note)" bash -ec "$(note_block "$NOTE" 'stable* endpoint' 2 | sed "s/blue-xxxxxxxx-yyyyy/$old/")"
wait || true
last=$(grep -o 'This is pod [^ ]*' requests.log | tail -1)
check "requests keep flowing to the replacement Pod" bash -c "[[ '$last' == *blue-* && '$last' != *$old ]]"

section "Load balancing"
check "kubectl scale deployment blue --replicas=3 (from the note)" bash -ec "$(block 'Load balancing' 1)"
kubectl rollout status deploy/blue --timeout=120s >/dev/null
retry 30 bash -c '[ "$(kubectl get endpointslices -l kubernetes.io/service-name=blue -o jsonpath="{.items[*].endpoints[*].addresses[0]}" | wc -w)" = 3 ]' || true
check_output "20 requests reach more than one Pod (from the note)" '^[23]$' \
  incluster "CLUSTER_IP=$CLUSTER_IP; $(block 'Load balancing' 2) | grep -o 'This is pod [^ ]*' | sort -u | wc -l"

section "DNS integration"
skip "kubectl run --rm -it --image=archlinux (from the note)" "interactive, and archlinux is amd64 only; the curl Pod stands in"
check_output "curl blue from a Pod in the same namespace (from the note)" 'This is pod' incluster "$(note_block "$NOTE" 'DNS integration' 2)"
check_fails "the nodes do not use the cluster DNS" docker exec "$CLUSTER-worker" getent hosts "blue.$TEST_NS.svc.cluster.local"

section "Under the hood"
conf=$(incluster 'cat /etc/resolv.conf')
assert_match "the search list starts with the Pod's namespace" "search $TEST_NS\.svc\.cluster\.local svc\.cluster\.local cluster\.local" "$conf"
assert_match "nameserver 10.96.0.10" '^nameserver 10\.96\.0\.10$' "$conf"
assert_match "options ndots:5" 'options ndots:5' "$conf"

section "nameserver 10.96.0.10"
check_output "kube-system has the kube-dns Service at that address (from the note)" '^kube-dns +ClusterIP +10\.96\.0\.10 ' \
  bash -ec "$(note_block "$NOTE" 'nameserver 10.96.0.10' 1)"
check_output "its Pods run CoreDNS" '^pod/coredns-' kubectl -n kube-system get pods -l k8s-app=kube-dns -o name

section "search default.svc.cluster.local ..."
check_output "blue.$TEST_NS.svc.cluster.local resolves" 'This is pod' incluster "curl -s blue.$TEST_NS.svc.cluster.local"
check_output "blue.$TEST_NS (with the svc.cluster.local search entry)" 'This is pod' incluster "curl -s blue.$TEST_NS"
