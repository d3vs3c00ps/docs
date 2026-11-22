#!/usr/bin/env bash
# note: kubernetes/workloads/namespaces.md
# env: kind
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/workloads/namespaces
KUBECTX_VERSION=v0.11.0
KUBE_PS1_VERSION=v1.0.0
cd "$(mktemp -d)"

# The cluster is shared: the note's blue and green Namespaces get unique names here,
# and are deleted on exit.
blue=$TEST_NS-blue green=$TEST_NS-green
cleanup() {
  local rc=$?
  kubectl delete namespace "$blue" "$green" --wait=false >/dev/null 2>&1 || true
  (exit "$rc")
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
# Docker Hub limits anonymous pulls per IP, and every test shares this IP.
# mirror.gcr.io serves the same Docker Hub images.
adapt() { sed -E -e "s/\bblue\b/$blue/g; s/\bgreen\b/$green/g" -e 's#(--image[= ])jpetazzo/#\1mirror.gcr.io/jpetazzo/#g'; }
# Blocks in a callout list keep the list's 2-space indent, which ends no heredoc.
run_block() { bash -ec "$(note_block "$NOTE" "$1" "${2:-1}" | sed 's/^  //' | adapt)"; }
active_ns() { kubectl config view --minify --output 'jsonpath={..namespace}'; }

section "Pre-existing Namespaces"
for ns in default kube-system kube-public kube-node-lease; do
  check "the $ns Namespace exists" kubectl get namespace "$ns"
done
check_output "kind adds local-path-storage" 'local-path-storage' kubectl get namespaces -o name
check "default holds the kubernetes Service" kubectl -n default get service kubernetes
check_output "kube-public holds cluster-info and kube-root-ca.crt" '^cluster-info kube-root-ca.crt $' \
  bash -c "kubectl -n kube-public get configmaps -o name | sed 's|configmap/||' | sort | tr '\n' ' '"
check "cluster-info can be read without authentication" \
  kubectl -n kube-public get configmap cluster-info --as=system:anonymous
check_output "every Namespace gets kube-root-ca.crt" '^configmap/kube-root-ca.crt$' kubectl get configmaps -o name
nodes=$(kubectl get nodes --no-headers | wc -l)
check_output "kube-node-lease holds one Lease per node ($nodes)" "^$nodes\$" \
  bash -c "kubectl -n kube-node-lease get leases --no-headers | wc -l"

section "Creating a Namespace"
check "kubectl create namespace (from the note)" run_block 'Creating a Namespace' 1
check "kubectl apply with a heredoc (from the note)" run_block 'Creating a Namespace' 2
check "the second Namespace exists" kubectl get namespace "$green"

section "Using namespaces"
check "kubectl create deployment --namespace (from the note)" run_block 'Using namespaces' 1
kubectl -n "$blue" rollout status deployment purple --timeout=180s >/dev/null
check_output "kubectl get pods --all-namespaces (from the note)" "^$blue +purple-" run_block 'Using namespaces' 2
check_output "-A is short for --all-namespaces" "^$blue +purple-" kubectl get pods -A --selector app=purple
check_output "without --namespace, the Pods are not in the current Namespace" '^$' \
  kubectl get pods --selector app=purple -o name

section "Method 1 (kubens/kns)"
arch=$(uname -m)
[[ $arch == aarch64 ]] && arch=arm64
curl -fsSL "https://github.com/ahmetb/kubectx/releases/download/$KUBECTX_VERSION/kubens_${KUBECTX_VERSION}_linux_$arch.tar.gz" | tar -xz kubens
PATH=$PWD:$PATH
check "kubens blue (from the note)" run_block 'Method 1' 1
assert_eq "the active Namespace is blue" "$blue" "$(active_ns)"
check_output "plain kubectl now lists the Pods of blue" '^pod/purple-' kubectl get pods -o name
check "kubens - switches back" kubens -
assert_eq "to the previous Namespace" "$TEST_NS" "$(active_ns)"

section "Method 2 (edit kubeconfig)"
check_output "the context has a namespace: field" "^ +namespace: $TEST_NS\$" cat "$KUBECONFIG"
sed -i "s/^\( *namespace:\) .*/\1 $blue/" "$KUBECONFIG"
check_output "after editing it, kubectl uses the new Namespace" '^pod/purple-' kubectl get pods -o name
sed -i "s/^\( *namespace:\) .*/\1 $TEST_NS/" "$KUBECONFIG"

section "Method 3 (kubectl config)"
check "kubectl config set-context --current --namespace (from the note)" run_block 'Method 3' 1
check_output "kubectl config view --minify shows it (from the note)" "^$blue\$" run_block 'Method 3' 2
check_output "kubectl config get-contexts shows NAME, CLUSTER, AUTHINFO, NAMESPACE" \
  "CURRENT +NAME +CLUSTER +AUTHINFO +NAMESPACE" kubectl config get-contexts
check_output "and the Namespace in the current context" "^\* .* $blue\$" kubectl config get-contexts
kubectl config set-context --current --namespace "$TEST_NS" >/dev/null
kubectl config set-context --current --namespace "" >/dev/null
check_output "an empty Namespace means default" '^service/kubernetes$' kubectl get services -o name
kubectl config set-context --current --namespace "$TEST_NS" >/dev/null

section "Namespaces, Services, and DNS"
img=mirror.gcr.io/library/busybox:1.37
check_output "a Pod's search list starts with its own Namespace" \
  "^search $TEST_NS.svc.cluster.local svc.cluster.local cluster.local" \
  kubectl run resolv --rm -i --quiet --restart=Never --image="$img" -- cat /etc/resolv.conf

section "Pods connecting to Services"
kubectl -n "$blue" expose deployment purple --name=auth --port=80 >/dev/null
kubectl create deployment local --image=mirror.gcr.io/jpetazzo/color >/dev/null
kubectl expose deployment local --name=auth --port=80 >/dev/null
kubectl rollout status deployment local --timeout=180s >/dev/null
kubectl run client --image="$img" -- sleep 3600 >/dev/null
kubectl wait --for=condition=Ready pod/client --timeout=120s >/dev/null
get() { kubectl exec client -- wget -qO- -T 5 "$1"; }
check_output "http://auth/ reaches the Service of the same Namespace" "local-" get http://auth/
for name in "auth.$blue" "auth.$blue.svc" "auth.$blue.svc.cluster.local"; do
  check_output "http://$name reaches the other Namespace" "purple-" get "http://$name/"
done

section "Namespaces and isolation"
check_output "by default, Pods in another Namespace can connect" "purple-" get "http://auth.$blue/"
kubectl -n "$blue" apply -f - >/dev/null <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: deny-all}
spec:
  podSelector: {}
  policyTypes: [Ingress]
YAML
check "a NetworkPolicy isolates them" retry 30 bash -c "! kubectl exec client -- wget -qO- -T 2 http://auth.$blue/"

section "Installing kube-ps1"
curl -fsSL -o kube-ps1.sh "https://raw.githubusercontent.com/jonmosco/kube-ps1/$KUBE_PS1_VERSION/kube-ps1.sh"
install=$(note_block "$NOTE" 'Installing `kube-ps1`' 1 | sed "s|/path/to/kube-ps1.sh|$PWD/kube-ps1.sh|")
# kube-ps1 refreshes its cache from PROMPT_COMMAND, which a non-interactive shell never runs.
prompt() { bash -c "$install"$'\n''_kube_ps1_prompt_update; '"$1"; }
check_output "the prompt shows (⎈|context:namespace) (from the note)" \
  "\(.*⎈.*\|.*kind-$CLUSTER.*:.*$TEST_NS.*\)" prompt 'echo "${PS1@P}"'
check_output "kube_ps1, kubeon and kubeoff are shell functions" '^function function function$' \
  prompt 'echo $(type -t kube_ps1 kubeon kubeoff)'
check_output "kubeoff hides it" '^\[' prompt 'kubeoff; echo "${PS1@P}"'
check_output "kubeoff empties kube_ps1" '^$' prompt 'kubeoff; kube_ps1'
