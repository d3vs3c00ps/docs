#!/usr/bin/env bash
# note: kubernetes/workloads/daemonset.md
# env: kind
# timeout: 1500
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/workloads/daemonset
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
cd "$(mktemp -d)"
# rate SECONDS: hashes per second, from the redis counter the workers update every second.
rate() {
  local a b
  a=$(kubectl exec deploy/redis -- redis-cli get hashes)
  sleep "$1"
  b=$(kubectl exec deploy/redis -- redis-cli get hashes)
  awk -v a="$a" -v b="$b" -v t="$1" 'BEGIN { printf "%.1f\n", (b - a) / t }'
}
count() { kubectl get pods "$@" --no-headers 2>/dev/null | grep -c . || true; }
ds_pods() { kubectl get pods -l app=rng,controller-revision-hash -o name; }
workers=$(kubectl get nodes --no-headers | grep -vc control-plane)

# Setup: DockerCoins with 10 workers, as scalingdockercoins.md leaves it.
kubectl apply -f "$UPSTREAM/k8s/dockercoins.yaml" >/dev/null
kubectl scale deployment worker --replicas=10 >/dev/null
for d in hasher redis rng webui worker; do kubectl rollout status "deploy/$d" --timeout=300s >/dev/null; done
sleep 15
before=$(rate 30)

section "Daemon sets in practice"
check "kube-proxy runs as a DaemonSet" kubectl -n kube-system get daemonset kube-proxy

section "Creating a daemon set"
check_fails "kubectl create has no daemonset subcommand (1.37)" kubectl create daemonset rng --image=dockercoins/rng:v0.1

section "Generating a Deployment manifest"
gen=$(bash -ec "$(note_block "$NOTE" 'Generating a Deployment manifest' 1)")
assert_match "it prints a Deployment (from the note)" 'kind: Deployment' "$gen"
assert_match "with replicas: 1" 'replicas: 1' "$gen"
assert_match "and strategy: {}" 'strategy: \{\}' "$gen"
check "save it to rng.yaml (from the note)" bash -ec "$(note_block "$NOTE" 'Generating a Deployment manifest' 2)"

section "Changing the kind"
check "sed changes the kind (from the note)" bash -ec "$(note_block "$NOTE" 'Changing the' 1)"
check_output "rng.yaml is now a DaemonSet" '^kind: DaemonSet$' grep '^kind:' rng.yaml

section "Creating the DaemonSet"
out=$(bash -c "$(note_block "$NOTE" 'Creating the DaemonSet' 1)" 2>&1) && rc=0 || rc=$?
check "kubectl apply fails (from the note)" test "$rc" -ne 0
assert_match "unknown field spec.replicas and spec.strategy" 'unknown field "spec.replicas", unknown field "spec.strategy"' "$out"

section "Fixing the problem"
sed '/replicas:/d' rng.yaml >replicas-only.yaml
check_fails "removing only replicas: is not enough (the correction)" kubectl apply --dry-run=server -f replicas-only.yaml
check_output "it still rejects spec.strategy" 'unknown field "spec.strategy"' bash -c "kubectl apply --dry-run=server -f replicas-only.yaml 2>&1; true"
check "remove replicas: and strategy: (from the note)" bash -ec "$(note_block "$NOTE" 'Fixing the problem' 1)"
check_output "kubectl apply works now (from the note)" 'daemonset.apps/rng created' bash -ec "$(note_block "$NOTE" 'Fixing the problem' 2)"
check "the daemon set becomes ready" kubectl rollout status ds/rng --timeout=300s

section "Checking what we've done"
all=$(bash -ec "$(note_block "$NOTE" "Checking what we've done" 1)")
assert_match "kubectl get all shows deployment.apps/rng (from the note)" 'deployment.apps/rng ' "$all"
assert_match "and daemonset.apps/rng" 'daemonset.apps/rng ' "$all"

section "deploy/rng and ds/rng"
check_output "the daemon set wants one Pod per worker node: DESIRED, CURRENT, READY = $workers" "^rng +$workers +$workers +$workers +$workers +$workers +<none>" kubectl get daemonset rng --no-headers
check_output "the deployment still has 1 Pod" '^rng +1/1 +1 +1' kubectl get deployment rng --no-headers

section "Too many pods"
check_output "one Pod for the deployment and one per node: $((workers + 1))" "^$((workers + 1))$" count -l app=rng
check_output "no daemon set Pod on the control plane" '^0$' bash -c "kubectl get pods -l app=rng,controller-revision-hash -o wide --no-headers | grep -c control-plane || true"
check_output "because the control plane has a NoSchedule taint" 'node-role.kubernetes.io/control-plane:NoSchedule' \
  kubectl get node "$CLUSTER-control-plane" -o jsonpath='{range .spec.taints[*]}{.key}:{.effect}{"\n"}{end}'

section "Is this working?"
sleep 15
after=$(rate 30)
check "the graph goes above 10 hashes/second ($before/s before, $after/s after)" awk -v r="$after" 'BEGIN { exit !(r > 12) }'
check_output "the new Pods are in the rng Service" "^$((workers + 1))$" bash -c "kubectl get endpointslices -l kubernetes.io/service-name=rng -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{\"\\n\"}{end}' | grep -c ."

section "Labels and selectors"
check_output "the selector of the rng Service is app=rng (from the note)" 'Selector: +app=rng$' bash -ec "$(note_block "$NOTE" 'Labels and selectors' 1)"

section "Selector evaluation"
check_output "kubectl get pods -l app=rng and --selector (from the note): a header and $((workers + 1)) Pods each" \
  "^$((2 * (workers + 1) + 2))$" bash -c 'bash -c "$1" | grep -c .' _ "$(note_block "$NOTE" 'Selector evaluation' 1)"

section "Where do labels come from?"
check_output "the Deployment, its ReplicaSet and its Pods have app=rng" '^rng rng rng$' bash -c \
  "echo \$(kubectl get deploy rng -o jsonpath='{.metadata.labels.app}') \$(kubectl get rs -l app=rng -o jsonpath='{.items[0].metadata.labels.app}') \$(kubectl get pods -l app=rng,pod-template-hash -o jsonpath='{.items[0].metadata.labels.app}')"
check_output "kubectl run stuff gives the label run=stuff" '"run":"stuff"' kubectl run stuff --image=alpine --dry-run=server -o jsonpath='{.metadata.labels}'

section "Updating load balancer configuration"
pod=$(ds_pods | sed -n 1p)
node=$(kubectl get "$pod" -o jsonpath='{.spec.nodeName}')
kubectl delete "$pod" --wait=false >/dev/null
check "a deleted daemon set Pod is re-created on its node" retry 60 bash -c \
  "kubectl get pods -l app=rng,controller-revision-hash --field-selector spec.nodeName=$node,status.phase=Running -o name | grep -v '^$pod\$' | grep -q ."
# The deleted Pod is still listed while it terminates: wait until it is gone.
kubectl wait --for=delete "$pod" --timeout=120s >/dev/null 2>&1 || true
kubectl rollout status ds/rng --timeout=120s >/dev/null
pod=$(ds_pods | sed -n 1p)
node=$(kubectl get "$pod" -o jsonpath='{.spec.nodeName}')
kubectl label "$pod" app- >/dev/null
check "removing app=rng from a Pod: the daemon set creates another on that node" retry 60 bash -c \
  "[ \$(kubectl get pods -l app=rng,controller-revision-hash --field-selector spec.nodeName=$node -o name | grep -c .) -eq 1 ] && ! kubectl get pods -l app=rng -o name | grep -qx '$pod'"
check_output "the old Pod keeps running" '^Running$' kubectl get "$pod" -o jsonpath='{.status.phase}'
check_output "and has no owner any more" '^$' kubectl get "$pod" -o jsonpath='{.metadata.ownerReferences}'
kubectl delete "$pod" --wait=false >/dev/null
kubectl rollout status ds/rng --timeout=120s >/dev/null

section "Selectors for replica sets and daemon sets"
hash=$(kubectl get rs -l app=rng -o jsonpath='{.items[0].metadata.labels.pod-template-hash}')
kubectl run fake --image=dockercoins/rng:v0.1 --labels="app=rng,pod-template-hash=$hash" >/dev/null
check_output "a controller adopts a Pod made by hand with the right labels (the ReplicaSet or the daemon set)" \
  '^(ReplicaSet|DaemonSet)$' retry_out 30 kubectl get pod fake -o jsonpath='{.metadata.ownerReferences[0].kind}'
check "and deletes one, to keep the right count ($((workers + 1)) Pods)" \
  retry 60 bash -c "[ \$(kubectl get pods -l app=rng --no-headers | grep -vc Terminating) -eq $((workers + 1)) ]"
# If the daemon set adopted the fake Pod, it may keep it: delete it, so that the note's later
# -l app=rng,pod-template-hash selects the Deployment's Pod only. Then wait for the counts to settle.
kubectl delete pod fake --ignore-not-found --wait=false >/dev/null
kubectl rollout status ds/rng --timeout=120s >/dev/null
kubectl rollout status deploy/rng --timeout=120s >/dev/null
# rng ignores SIGTERM: deleted Pods stay Terminating for 30 s. Let them go before counting.
retry 90 bash -c "! kubectl get pods -l app=rng --no-headers | grep -q Terminating"

section "Isolation of replica sets and daemon sets"
check_output "the ReplicaSet selector includes pod-template-hash" 'pod-template-hash' kubectl get rs -l app=rng -o jsonpath='{.items[0].spec.selector}'
check_output "the daemon set selector is only app=rng (the correction)" '^\{"matchLabels":\{"app":"rng"\}\}$' kubectl get ds rng -o jsonpath='{.spec.selector}'
check_output "its Pods have a controller-revision-hash label" '[0-9a-f]+' bash -c "kubectl get $(ds_pods | head -1) -o jsonpath='{.metadata.labels.controller-revision-hash}'"
check_output "and an owner reference to the daemon set" '^DaemonSet/rng$' bash -c "kubectl get $(ds_pods | head -1) -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}'"

section "Adding labels to pods"
check "kubectl label pods -l app=rng active=yes (from the note)" bash -ec "$(note_block "$NOTE" 'Adding labels to pods' 1)"
check_output "all rng Pods have active=yes" "^$((workers + 1))$" count -l app=rng,active=yes

section "Updating the service selector"
# KUBE_EDITOR plays the user: add the line under `selector:` only.
add_sel() { printf "sed -i -e '/^  selector:/a\\\\    active: %s' " "$1"; }
out=$(KUBE_EDITOR="$(add_sel yes)" bash -c "$(note_block "$NOTE" 'Updating the service selector' 1)" 2>&1) && rc=0 || rc=$?
check "kubectl edit with active: yes fails (from the note)" test "$rc" -ne 0
copy=$(grep -o '/[^"]*kubectl-edit-[0-9]*.yaml' <<<"$out" | sed -n 1p)
check_output "the error is the one the note shows" "$(note_block "$NOTE" 'Updating the service selector' 2 | sed -n 2p | sed 's/[][*.()^$]/\\&/g')" cat "$copy"

section "When the YAML parser is being too smart"
svc_with() { printf 'apiVersion: v1\nkind: Service\nmetadata: {name: parse}\nspec:\n  selector: {app: rng, active: %s}\n  ports: [{port: 80}]\n' "$1" | kubectl apply --dry-run=server -f - 2>&1; }
check_output "yes is the boolean true: kubectl apply gives the other message (from the note)" \
  "$(note_block "$NOTE" 'Updating the service selector' 3)" bash -c "$(declare -f svc_with); svc_with yes; true"
check_output "42 is a number" 'cannot unmarshal number' bash -c "$(declare -f svc_with); svc_with 42; true"
check "\"yes\" is a string" svc_with '"yes"'
check "oui is a string" svc_with oui

section "Updating the service selector, take 2"
check "kubectl edit with active: \"yes\" works" env KUBE_EDITOR="$(add_sel '"yes"')" kubectl edit service rng
check_output "the selector is now active=yes,app=rng" '^\{"active":"yes","app":"rng"\}$' kubectl get svc rng -o jsonpath='{.spec.selector}'
check_output "all Pods still serve traffic" "^$((workers + 1))$" bash -c "kubectl get endpointslices -l kubernetes.io/service-name=rng -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{\"\\n\"}{end}' | grep -c ."

section "Updating labels"
p=$(ds_pods | sed -n 1p)
kubectl label "$p" foo= >/dev/null
check_output "foo= sets the label to an empty string" '^"foo":""$' bash -c "kubectl get $p -o json | jq -c '.metadata.labels | {foo}' | tr -d '{}'"
check "foo- removes it" bash -c "kubectl label $p foo- && ! kubectl get $p -o jsonpath='{.metadata.labels}' | grep -q foo"
kubectl label "$p" foo=bar >/dev/null
check_fails "changing a label needs --overwrite" kubectl label "$p" foo=baz
check "with --overwrite it works" kubectl label "$p" foo=baz --overwrite

section "Removing a pod from the load balancer, in practice"
blk1=$(note_block "$NOTE" 'load balancer, in practice' 1)
{ timeout 60 bash -c "$blk1" >stream.log 2>&1 & } 2>/dev/null
eval "$(sed -n 1p <<<"$blk1")"
ip=$(kubectl get "$POD" -o jsonpath='{.status.podIP}')
check "the Pod of the deployment gets a steady stream of requests" retry 50 bash -c '[ $(grep -c "GET /32" stream.log) -ge 3 ]'
check "remove its active label (from the note)" bash -ec "$(note_block "$NOTE" 'load balancer, in practice' 2)"
check "it leaves the Service's EndpointSlice" retry 20 bash -c "! kubectl get endpointslices -l kubernetes.io/service-name=rng -o jsonpath='{.items[*].endpoints[*].addresses[0]}' | grep -qw '$ip'"
sleep 5
n1=$(grep -c 'GET /32' stream.log)
sleep 10
n2=$(grep -c 'GET /32' stream.log)
check "the stream of HTTP logs stops ($n1 then $n2 requests)" test "$n1" -eq "$n2"
check_output "the Pod is still running, for debugging" '^Running$' kubectl get "$POD" -o jsonpath='{.status.phase}'

section "We've put resources in your resources"
check_output "the daemon set selector is immutable (the correction)" 'field is immutable' bash -c \
  "kubectl patch ds rng --type=merge -p '{\"spec\":{\"selector\":{\"matchLabels\":{\"active\":\"yes\"}},\"template\":{\"metadata\":{\"labels\":{\"active\":\"yes\"}}}}}' 2>&1; true"
check_output "a template the selector would not match is refused" 'does not match template' bash -c \
  "kubectl patch ds rng --type=json -p '[{\"op\":\"replace\",\"path\":\"/spec/template/metadata/labels\",\"value\":{\"active\":\"yes\"}}]' 2>&1; true"
check "adding active=yes to the template is enough" kubectl patch ds rng --type=merge -p '{"spec":{"template":{"metadata":{"labels":{"active":"yes"}}}}}'
check "it starts a rolling update" kubectl rollout status ds/rng --timeout=300s
check "the new daemon set Pods have active=yes ($workers, once the old ones are gone)" retry 90 bash -c "[ \$(kubectl get pods -l app=rng,controller-revision-hash,active=yes --no-headers | grep -vc Terminating) -eq $workers ]"

section "Example of advanced selector"
sel=$(note_block "$NOTE" 'Example of advanced selector' 1 | sed 's/theSelector:/selector:/')
mkdeploy() {
  printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata: {name: portal}\nspec:\n%s\n  template:\n    metadata:\n      labels: %s\n    spec:\n      containers: [{name: c, image: dockercoins/rng:v0.1}]\n' "$sel" "$1"
}
check "the selector is accepted, with a template that matches it" bash -c "$(declare -p sel); $(declare -f mkdeploy); mkdeploy '{app: portal, component: api, release: production, signed-off-by: me}' | kubectl apply --dry-run=server -f -"
check_output "a template without signed-off-by is refused" 'does not match template' bash -c \
  "$(declare -p sel); $(declare -f mkdeploy); mkdeploy '{app: portal, component: api, release: production}' | kubectl apply --dry-run=server -f - 2>&1; true"
check_output "the command-line form parses" 'No resources found' bash -c \
  "kubectl get pods -l 'app=portal,component=api,release in (production,preproduction),signed-off-by' 2>&1"
check_output "a Deployment must have a non-empty selector" 'empty selector is invalid' bash -c \
  "kubectl create deployment e --image=x --dry-run=client -o json | jq '.spec.selector = {}' | kubectl apply --dry-run=server -f - 2>&1; true"
# A PodDisruptionBudget shows both: {} selects every Pod of the namespace, no selector none.
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: everything}
spec: {minAvailable: 1, selector: {}}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: nothing}
spec: {minAvailable: 1}
YAML
all_pods=$(kubectl get pods --no-headers | grep -c .)
check "a {} selector matches every Pod ($all_pods)" retry 30 bash -c "[ \"\$(kubectl get pdb everything -o jsonpath='{.status.expectedPods}')\" = $all_pods ]"
check_output "no selector matches nothing" '^0$' retry_out 30 kubectl get pdb nothing -o jsonpath='{.status.expectedPods}'
kubectl delete pdb everything nothing >/dev/null

section "Services and EndpointSlices"
check "the rng Service has an EndpointSlice" kubectl get endpointslices -l kubernetes.io/service-name=rng -o name
check_output "kubectl get endpoints is deprecated" 'v1 Endpoints is deprecated' bash -c 'kubectl get endpoints rng 2>&1'
check_output "the Endpoints object is still kept up to date" '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:80' bash -c 'kubectl get endpoints rng 2>/dev/null'
check_output "kube-proxy may list EndpointSlices" '^yes$' kubectl auth can-i list endpointslices.discovery.k8s.io --as=system:serviceaccount:kube-system:kube-proxy
slice=$(kubectl get endpointslices -l kubernetes.io/service-name=rng -o name | sed -n 1p)
kubectl patch "$slice" --type=json -p '[{"op":"add","path":"/endpoints/-","value":{"addresses":["10.255.255.1"]}}]' >/dev/null
check "a change by hand is overwritten" retry 60 bash -c "! kubectl get endpointslices -l kubernetes.io/service-name=rng -o jsonpath='{.items[*].endpoints[*].addresses[0]}' | grep -qw 10.255.255.1"

section "Empty Service selector"
target=$(kubectl get "$(ds_pods | sed -n 1p)" -o jsonpath='{.status.podIP}')
kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Service
metadata: {name: external}
spec:
  ports: [{name: http, port: 80}]
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: external-1
  labels: {kubernetes.io/service-name: external}
addressType: IPv4
ports: [{name: http, port: 80}]
endpoints: [{addresses: ["$target"]}]
YAML
kubectl run client --image=alpine --image-pull-policy=IfNotPresent --command -- sleep 3600 >/dev/null
kubectl wait --for=condition=Ready pod/client --timeout=180s >/dev/null
check_output "a Service with no selector uses a hand-made EndpointSlice" 'RNG running on' retry_out 30 kubectl exec client -- wget -qO- -T 3 http://external/
sleep 5
check_output "and nothing overwrites it" "$target" kubectl get endpointslice external-1 -o jsonpath='{.endpoints[*].addresses[0]}'
check_output "the kubernetes Service has no selector" '^$' kubectl -n default get svc kubernetes -o jsonpath='{.spec.selector}'
check "but it has endpoints, kept by the API server" bash -c "kubectl -n default get endpointslices -l kubernetes.io/service-name=kubernetes -o jsonpath='{.items[0].endpoints[0].addresses[0]}' | grep -qE '[0-9]+\.'"
