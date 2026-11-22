#!/usr/bin/env bash
# note: kubernetes/extending/extending-api.md
# env: kind
# timeout: 300
# The policies are cluster-wide objects: they match only the test namespace, and are deleted on exit.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

P=notes-$TEST_NS
cleanup() {
  kubectl delete validatingadmissionpolicybinding,validatingadmissionpolicy,mutatingadmissionpolicybinding,mutatingadmissionpolicy \
    "$P" --ignore-not-found >/dev/null 2>&1
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
CP=$(kubectl get nodes -o name | grep control-plane | head -1 | cut -d/ -f2)

section "Admission controllers"
help=$(kubectl -n kube-system exec "kube-apiserver-$CP" -- kube-apiserver --help 2>&1 | tr -s ' \n' ' ')
# "--enable-admission-plugins strings admission plugins that should be enabled in addition to default enabled ones (A, B, ...). Comma-delimited list of admission plugins: ..."
defaults=$(grep -o -- '--enable-admission-plugins strings [^(]*([^)]*)' <<<"$help" | sed 's/.*(//; s/)$//')
all=$(grep -o -- '--enable-admission-plugins strings .*Comma-delimited list of admission plugins: [^.]*' <<<"$help" | sed 's/.*plugins: //')
assert_match "ServiceAccount is enabled by default (from the note)" '(^|, )ServiceAccount(,|$)' "$defaults"
assert_match "LimitRanger is enabled by default (from the note)" '(^|, )LimitRanger(,|$)' "$defaults"
assert_match "NamespaceAutoProvision exists (from the note)" '(^|, )NamespaceAutoProvision(,|$)' "$all"
assert_no_match "but is not on by default (from the note)" 'NamespaceAutoProvision' "$defaults"
kubectl run sa-check --image=busybox:1.37 --restart=Never -- true >/dev/null
check_output "ServiceAccount adds a ServiceAccount to Pods that do not specify one (from the note)" '^default$' \
  kubectl get pod sa-check -o jsonpath='{.spec.serviceAccountName}'
check_output "with no NamespaceAutoProvision, a missing namespace is an error" 'namespaces "notes-nope-[0-9]+" not found' \
  bash -c "kubectl -n notes-nope-$RANDOM create configmap x 2>&1; true"

section "Validating Admission Policies"
check_output "GA: admissionregistration.k8s.io/v1 (from the note)" '^validatingadmissionpolicies +admissionregistration.k8s.io/v1 ' \
  bash -c "kubectl api-resources --api-group=admissionregistration.k8s.io --no-headers | tr -s ' '  | sed 's/ /  /'"
kubectl apply -f - >/dev/null <<EOF
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata: {name: $P}
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - {apiGroups: [""], apiVersions: [v1], operations: [CREATE, UPDATE], resources: [configmaps]}
  validations:
  - expression: "!has(object.data) || !object.data.exists(k, k == 'password')"
    message: no passwords in ConfigMaps
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata: {name: $P}
spec:
  policyName: $P
  validationActions: [Deny]
  matchResources:
    namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: $TEST_NS}}
EOF
check_output "a CEL rule, checked in the API server, refuses the request (from the note)" 'no passwords in ConfigMaps' bash -c \
  "for i in \$(seq 30); do out=\$(kubectl create configmap leak --from-literal=password=x 2>&1) || { echo \"\$out\"; exit; }; kubectl delete configmap leak >/dev/null; sleep 1; done"
check "and lets the others through" kubectl create configmap fine --from-literal=user=x

section "Mutating admission policies"
check_output "GA in Kubernetes 1.36: served as v1 here (the correction)" '^mutatingadmissionpolicies +admissionregistration.k8s.io/v1 ' \
  bash -c "kubectl api-resources --api-group=admissionregistration.k8s.io --no-headers | tr -s ' ' | sed 's/ /  /'"
kubectl apply -f - >/dev/null <<EOF
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicy
metadata: {name: $P}
spec:
  failurePolicy: Fail
  reinvocationPolicy: Never
  matchConstraints:
    resourceRules:
    - {apiGroups: [""], apiVersions: [v1], operations: [CREATE], resources: [configmaps]}
  mutations:
  - patchType: ApplyConfiguration
    applyConfiguration:
      expression: "Object{metadata: Object.metadata{labels: {'checked-by': 'cel'}}}"
---
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicyBinding
metadata: {name: $P}
spec:
  policyName: $P
  matchResources:
    namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: $TEST_NS}}
EOF
check_output "a CEL mutation adds a label, with no webhook" '^cel$' bash -c \
  "for i in \$(seq 30); do kubectl create configmap m\$i >/dev/null; l=\$(kubectl get configmap m\$i -o jsonpath='{.metadata.labels.checked-by}'); [ -n \"\$l\" ] && { echo \$l; exit; }; sleep 1; done"

section "The aggregation layer"
check_output "kubectl get apiservices: built-in groups are Local (from the note)" '^v1\.apps +Local +True' \
  kubectl get apiservices v1.apps
