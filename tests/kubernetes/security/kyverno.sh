#!/usr/bin/env bash
# note: kubernetes/security/kyverno.md
# env: kind
# timeout: 2400
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
source "$NOTES_ROOT/tests/kubernetes/security/kyverno-lib.bash"

NOTE=kubernetes/security/kyverno
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
use_test_namespace
WORK=$(mktemp -d)
cd "$WORK"
cleanup() {
  kubectl delete namespace kyv-gen-probe --ignore-not-found --wait=false >/dev/null 2>&1
  kyverno_cleanup
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
rejected() { "$@" || true; }

# policy NAME KIND FRAGMENT [FAILURE_ACTION]: a ClusterPolicy with one rule that
# matches KIND and carries the note's fragment as its action.
policy() {
  local frag
  frag=$(reindent 4 <<<"$3")
  # shellcheck disable=SC2001 # anchored, per-line edit of a multi-line string
  if [[ -n ${4:-} ]]; then frag=$(sed "s/^    validate:\$/    validate:\n      failureAction: $4/" <<<"$frag"); fi
  kubectl apply -f - >/dev/null <<EOF
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata: {name: $1}
spec:
  rules:
  - name: $1
    match:
      any:
      - resources: {kinds: [$2]}
$frag
EOF
  kubectl wait --for=condition=Ready "clusterpolicy/$1" --timeout=120s >/dev/null
}

section "Installing Kyverno"
assert_match "the note pins the chart version the tests use" "--version $KYVERNO_CHART" \
  "$(note_block "$NOTE" 'Installing Kyverno' 1)"
check "the note's helm command" bash -ec "$(note_block "$NOTE" 'Installing Kyverno' 1)"
kyverno_wait

section "Custom resource definitions"
for r in policies.kyverno.io clusterpolicies.kyverno.io policyreports.wgpolicyk8s.io \
  clusterpolicyreports.wgpolicyk8s.io updaterequests.kyverno.io; do
  check "the CRD $r is registered" kubectl get crd "$r"
done
check "kubectl get clusterpolicyreports --all-namespaces works (from the note)" \
  kubectl get clusterpolicyreports --all-namespaces

section "Footprint (current versions)"
assert_eq "22 CRDs" 22 "$(kubectl get crd -o name | grep -cE 'kyverno\.io|wgpolicyk8s\.io')"
# The admission controller registers most of them a few seconds after it starts.
retry 60 bash -c "[ \$(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -c kyverno) -ge 10 ]" || true
assert_eq "10 webhook configurations before any policy" 10 \
  "$(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -c kyverno)"
assert_eq "6 Services" 6 "$(kubectl -n kyverno get svc --no-headers | wc -l | tr -d ' ')"
assert_eq "4 Deployments" 4 "$(kubectl -n kyverno get deploy --no-headers | wc -l | tr -d ' ')"
assert_eq "2 ConfigMaps (besides kube-root-ca.crt)" 2 \
  "$(kubectl -n kyverno get cm --no-headers | grep -vc kube-root-ca)"

section "Validating objects"
policy require-resources Pod "$(note_block "$NOTE" 'Validating objects' 1)"
audit_out=$(kubectl run no-resources --image=nginx:1.29 --restart=Never 2>&1)
check "failureAction defaults to Audit: the violating Pod is admitted" kubectl get pod no-resources
assert_no_match "without emitWarning, no API warning (the note's correction)" \
  'Warning: policy require-resources' "$audit_out"
check "and a PolicyReport records the failure" retry 120 bash -c \
  "kubectl get policyreports -o json | jq -e '[.items[].results[]? | select(.policy==\"require-resources\" and .result==\"fail\")] | length > 0' >/dev/null"
kubectl patch clusterpolicy require-resources --type=merge -p '{"spec":{"emitWarning":true}}' >/dev/null 2>&1
kubectl wait --for=condition=Ready clusterpolicy/require-resources --timeout=60s >/dev/null
sleep 5
check_output "emitWarning: true adds the API warning, policy.rule: message" \
  'Warning: policy require-resources\.require-resources: validation error: CPU and memory' \
  kubectl run no-resources-warn --image=nginx:1.29 --restart=Never
policy require-resources Pod "$(note_block "$NOTE" 'Validating objects' 1)" Enforce
check_output "with failureAction: Enforce, it is rejected with the note's message" \
  'CPU and memory resource requests and memory limits are required' \
  rejected kubectl run no-resources-2 --image=nginx:1.29 --restart=Never
check "a Pod that sets them is admitted" kubectl run with-resources --image=nginx:1.29 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"c","image":"nginx:1.29","resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"memory":"64Mi"}}}]}}'
kubectl delete clusterpolicy require-resources >/dev/null

section "Optional fields"
policy no-nodeport Service "$(note_block "$NOTE" 'Optional fields' 1)" Enforce
check_output "a NodePort Service is rejected" 'Services of type NodePort are not allowed' \
  rejected kubectl create service nodeport np --tcp=80:80
check "a ClusterIP Service is admitted" kubectl create service clusterip cip --tcp=80:80
check "=(type): a Service without the field is admitted too" bash -c \
  'kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata: {name: notype}
spec: {ports: [{port: 80}]}
EOF'
kubectl delete clusterpolicy no-nodeport >/dev/null

section "Loops"
policy tag-loop Pod "$(note_block "$NOTE" 'Loops' 1)" Enforce
check_output "foreach: an image without a tag is rejected" 'An image tag is required' \
  rejected kubectl run untagged --image=nginx --restart=Never
check "an image with a tag is admitted" kubectl run tagged --image=nginx:1.29 --restart=Never

section "Autogen rules for Pod validating policies"
check_output "Kyverno generated rules for Pod controllers" 'autogen-tag-loop' \
  kubectl get clusterpolicy tag-loop -o jsonpath='{.status.autogen.rules[*].name}'
check_output "so a Deployment with an untagged image is rejected, not only its Pods" \
  'An image tag is required' rejected kubectl create deployment untagged --image=nginx
kubectl delete clusterpolicy tag-loop >/dev/null

section "...Or not to loop"
policy tag-pattern Pod "$(note_block "$NOTE" '...Or not to loop' 1)" Enforce
check_output "the pattern version rejects an untagged image too" 'An image tag is required' \
  rejected kubectl run untagged-2 --image=nginx --restart=Never
check "and admits a tagged one" kubectl run tagged-2 --image=nginx:1.29 --restart=Never
kubectl delete clusterpolicy tag-pattern >/dev/null

section "Generating objects (In practice)"
curl -fsSL "$UPSTREAM/k8s/kyverno-namespace-setup.yaml" >ns-setup.yaml
assert_match "the note's excerpt comes from the upstream policy" 'name: default-limitrange' "$(cat ns-setup.yaml)"
check_output "the upstream policy, without apiVersion, is refused (the note's correction)" \
  'apiVersion can not be empty' rejected kubectl apply -f ns-setup.yaml
# The fix the note gives: an apiVersion under each generate.
sed -i -E 's/^( *)kind: (LimitRange|ResourceQuota) *$/\1apiVersion: v1\n\1kind: \2/;
           s/^( *)kind: NetworkPolicy *$/\1apiVersion: networking.k8s.io\/v1\n\1kind: NetworkPolicy/' ns-setup.yaml
check "with apiVersion added, it is accepted" kubectl apply -f ns-setup.yaml
kubectl wait --for=condition=Ready clusterpolicy --all --timeout=120s >/dev/null
kubectl create namespace kyv-gen-probe >/dev/null
check "creating a Namespace generates its LimitRange" \
  retry 60 kubectl -n kyv-gen-probe get limitrange default-limitrange
check "and its ResourceQuota and NetworkPolicy (3 rules, 3 resources)" retry 60 bash -c \
  "[ \$(kubectl -n kyv-gen-probe get resourcequota,networkpolicy -o name | wc -l) -ge 2 ]"
kubectl delete -f ns-setup.yaml >/dev/null

section "Kubernetes API calls"
ctx=$(note_block "$NOTE" 'Kubernetes API calls' 1)
mut=$(note_block "$NOTE" 'Kubernetes API calls' 2)
policy add-dns Pod "$(printf '%s\n%s\n' "$ctx" "$mut")"
kubectl run dns-env --image=busybox --restart=Never -- sleep 600 >/dev/null
check_output "apiCall + mutate: the Pod gets DNS=<kube-dns ClusterIP>" \
  "^$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}')\$" \
  kubectl get pod dns-env -o jsonpath='{.spec.containers[0].env[?(@.name=="DNS")].value}'
kubectl delete clusterpolicy add-dns >/dev/null
