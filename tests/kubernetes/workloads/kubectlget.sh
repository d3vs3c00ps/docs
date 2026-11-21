#!/usr/bin/env bash
# note: kubernetes/workloads/kubectlget.md
# env: kind
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/workloads/kubectlget
cd "$(mktemp -d)"
nodes=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
cp=$CLUSTER-control-plane
# The note's node1 is a placeholder: use our control plane node.
node1() { note_block "$NOTE" "$1" "${2:-1}" | sed "s/node1/$cp/g"; }

section "First contact with kubectl"
check "--kubeconfig points to a config file" kubectl --kubeconfig "$KUBECONFIG" get namespace default
server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
check_output "the kubeconfig holds the API address" '^https://' echo "$server"

section "kubectl get"
check_output "kubectl get node lists the nodes (from the note)" "$cp +Ready" bash -ec "$(note_block "$NOTE" 'kubectl get' 1)"
a=$(kubectl get no -o name) b=$(kubectl get node -o name) c=$(kubectl get nodes -o name)
check "no, node and nodes are the same" test "$a" = "$b" -a "$b" = "$c"
check "the three commands run (from the note)" bash -ec "$(note_block "$NOTE" 'kubectl get' 2)"

section "Obtaining machine-readable output"
check_output "-o wide adds INTERNAL-IP (from the note)" 'INTERNAL-IP' bash -ec "$(note_block "$NOTE" 'machine-readable' 1)"
check_output "-o yaml ends with kind: List (from the note)" '^kind: List$' \
  bash -ec "$(note_block "$NOTE" 'machine-readable' 2) | grep -v '^ ' | grep '^kind:'"

section "(Ab)using kubectl and jq"
check_output "one JSON object per node, with name and capacity (from the note)" "^$nodes\$" \
  bash -ec "$(note_block "$NOTE" 'jq' 1) | jq -s 'map(select(.name and .cpu and .memory)) | length'"

section "Exploring types and definitions"
check_output "kubectl api-resources lists nodes" '^nodes +no +v1 +false +Node' kubectl api-resources
check_fails "'type' is a placeholder, not a resource type" bash -ec "$(note_block "$NOTE" 'Exploring types' 1)"
check_output "kubectl explain node.spec (from the note)" 'FIELD: spec' bash -ec "$(note_block "$NOTE" 'Exploring types' 2)"
check_output "kubectl explain node --recursive shows sub-fields (from the note)" 'taints\s+<\[\]Taint>' \
  bash -ec "$(note_block "$NOTE" 'Exploring types' 3)"

section "Type names"
check_output "short names: no, svc, deploy" '^nodes +no .*services +svc .*deployments +deploy ' \
  bash -c "kubectl api-resources --no-headers | grep -E '^(nodes|services|deployments) ' | tr '\n' ' '"
check "service and services are both accepted" bash -c 'kubectl -n default get service kubernetes && kubectl -n default get services kubernetes'
check_fails "Endpoints has no singular form" kubectl -n default get endpoint kubernetes
check "endpoints works" kubectl -n default get endpoints kubernetes
check "and its short name ep" kubectl -n default get ep kubernetes
check_output "the v1 Endpoints API is deprecated since 1.33" 'Endpoints is deprecated in v1.33\+' \
  kubectl -n default get endpoints kubernetes
check "EndpointSlices replace it" kubectl -n default get endpointslices -l kubernetes.io/service-name=kubernetes

section "Viewing details"
check_output "get -o yaml lists the images on the node" 'images:' kubectl get node "$cp" -o yaml
check "but not the Pods on the node" bash -c "! kubectl get node $cp -o yaml | grep -q 'kube-apiserver-$cp'"

section "kubectl describe"
check_output "describe node/NAME shows control plane Pods (from the note)" "kube-apiserver-$cp" \
  bash -ec "$(node1 'kubectl describe' 1 | head -1)"
check_output "describe node NAME, the other form (from the note)" "etcd-$cp" bash -ec "$(node1 'kubectl describe' 1 | tail -1)"
check_output "a name prefix describes every matching node" "^2\$" \
  bash -c "kubectl describe node $CLUSTER-work | grep -c '^Name:'"
check_output "but an exact name wins over the prefix" "^1\$" \
  bash -c "kubectl describe node $CLUSTER-worker | grep -c '^Name:'"

section "Listing running containers"
check_output "no Pods in our namespace yet (from the note)" 'No resources found' bash -ec "$(note_block "$NOTE" 'Listing running containers' 1) 2>&1"

section "Namespaces"
for i in 1 2 3; do
  check_output "kubectl get namespaces, form $i, lists kube-system" '^kube-system +Active' \
    bash -ec "$(note_block "$NOTE" '## Namespaces' 1 | sed -n "${i}p")"
done

section "Accessing namespaces"
check_output "--all-namespaces shows the system Pods (from the note)" '^kube-system +kube-apiserver-' bash -ec "$(note_block "$NOTE" 'Accessing namespaces' 1)"
check_output "-A is the same (from the note)" '^kube-system +etcd-' bash -ec "$(note_block "$NOTE" 'Accessing namespaces' 2)"

section "What are all these control plane pods?"
pods=$(kubectl get pods -n kube-system -o name)
for p in etcd kube-apiserver kube-controller-manager kube-scheduler coredns kube-proxy kindnet; do
  assert_match "kube-system runs $p" "pod/$p-" "$pods"
done
ds=$(kubectl -n kube-system get daemonsets -o name)
assert_match "kube-proxy runs on every node (a DaemonSet)" 'daemonset.apps/kube-proxy' "$ds"
assert_match "the CNI plugin on kind, kindnet, too" 'daemonset.apps/kindnet' "$ds"

section "Scoping another namespace"
check_output "--namespace=kube-system (from the note)" '^coredns-' bash -ec "$(note_block "$NOTE" 'Scoping another namespace' 1 | head -1)"
check_output "-n kube-system (from the note)" '^coredns-' bash -ec "$(note_block "$NOTE" 'Scoping another namespace' 1 | tail -1)"

section "Namespaces and other kubectl commands"
kubectl create namespace "$TEST_NS-b" >/dev/null
# Same as _k8s_exit (lib/k8s.sh), with our extra namespace deleted; keeps the test's status.
cleanup() {
  local rc=$?
  kubectl delete namespace "$TEST_NS-b" --wait=false >/dev/null 2>&1 || true
  _k8s_stop_cpk
  _k8s_cleanup
  _t_finish "$rc"
}
trap '_k8s_rc=$?; cleanup' EXIT
# Unique names and label value: -A reaches other tests' namespaces too.
cm=cm-$TEST_NS
kubectl create configmap "$cm" --from-literal=a=1 >/dev/null
check "kubectl create --namespace=X" kubectl create --namespace="$TEST_NS-b" configmap "$cm" --from-literal=a=1
check "kubectl label -A labels across namespaces" kubectl label configmaps -A --field-selector "metadata.name=$cm" "notes-test=$TEST_NS"
check_output "both ConfigMaps got the label" '^2$' bash -c "kubectl get cm -A -l notes-test=$TEST_NS --no-headers | wc -l"
check "kubectl delete -A deletes across namespaces" kubectl delete configmaps -A -l "notes-test=$TEST_NS"
check_output "both are gone" '^0$' bash -c "kubectl get cm -A -l notes-test=$TEST_NS --no-headers 2>/dev/null | wc -l"

section "What about kube-public?"
check_output "kube-public has no Pods (from the note)" 'No resources found' bash -ec "$(note_block "$NOTE" 'What about `kube-public`' 1) 2>&1"

section "Exploring kube-public"
check_output "kube-public has cluster-info (from the note)" '^cluster-info ' bash -ec "$(note_block "$NOTE" 'Exploring `kube-public`' 1)"
check_output "and kube-root-ca.crt, like every namespace" '^kube-root-ca.crt ' kubectl -n kube-public get configmaps
check_output "cluster-info holds a kubeconfig (from the note)" '^  kubeconfig: \|' bash -ec "$(note_block "$NOTE" 'Exploring `kube-public`' 2)"
check "and no selfLink since Kubernetes 1.20" bash -c "! kubectl -n kube-public get configmap cluster-info -o yaml | grep -q selfLink"

section "Accessing cluster-info"
apiip=$(kubectl -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}')
assert_eq "the kubernetes Service has the note's address" "10.96.0.1" "$apiip"
kubectl run curl --image=quay.io/curl/curl --restart=Never --command -- sleep 600 >/dev/null
kubectl wait --for=condition=Ready pod/curl --timeout=120s >/dev/null
# Run the note's curl inside the Pod; jq stays on this side, the curl image has none.
incluster() { sed -e 's/^ *curl/kubectl exec curl -- curl/' -e 's/\\$//' | tr '\n' ' '; }
check_output "anyone can read cluster-info, without authentication (from the note)" '"name": "cluster-info"' \
  bash -ec "$(note_block "$NOTE" 'Accessing `cluster-info`' 1 | incluster)"

section "Retrieving kubeconfig"
out=$(bash -ec "$(note_block "$NOTE" 'Retrieving `kubeconfig`' 1 | incluster)")
assert_match "it holds the API server address" "server: https://$cp:6443" "$out"
assert_match "and the CA certificate" 'certificate-authority-data:' "$out"
assert_no_match "but no client key or token" 'client-key|token:' "$out"

section "What about kube-node-lease?"
check_output "one Lease per node" "^$nodes\$" bash -c "kubectl -n kube-node-lease get leases --no-headers | wc -l"

section "Services"
check_output "kubectl get services: the kubernetes Service in default (from the note)" '^kubernetes +ClusterIP +10\.96\.0\.1 ' \
  bash -ec "$(note_block "$NOTE" '## Services' 1 | head -1) -n default"
check_output "kubectl get svc is the same (from the note)" '^kubernetes ' bash -ec "$(note_block "$NOTE" '## Services' 1 | tail -1) -n default"

section "Time out"
check_fails "a ClusterIP cannot be reached from outside the cluster" curl -sk --max-time 5 https://10.96.0.1
# kubectl run -i can attach after a short command has already ended and print nothing:
# try a few times.
once=$(note_block "$NOTE" 'Time out' 1 | sed 's/kubectl run curl /kubectl run curl-once /')
check_output "from a Pod, the API answers (the note's command)" '"code": 403' \
  bash -c "for i in 1 2 3 4 5; do out=\$($once 2>/dev/null); grep -q code <<<\"\$out\" && break; done; echo \"\$out\""

section "Authentication error"
note_out=$(note_block "$NOTE" 'Authentication error' 1 | sed 1d | tr -d ' \n')
real=$(kubectl exec curl -- curl -sk "https://$apiip" | tr -d ' \n')
assert_eq "the reply is the one shown in the note" "$note_out" "$real"

section "DNS integration"
check_output "kubernetes.default resolves from any namespace" '"major": "1"' kubectl exec curl -- curl -sk https://kubernetes.default/version
check_fails "the short name only works in the default namespace" kubectl exec curl -- curl -sk --max-time 10 https://kubernetes/version
