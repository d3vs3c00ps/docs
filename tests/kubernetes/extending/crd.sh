#!/usr/bin/env bash
# note: kubernetes/extending/crd.md
# env: kind
# timeout: 600
# The Pizza CRD is cluster-wide: it is deleted on exit.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/extending/crd
HOME=$(mktemp -d)
export HOME
cd "$HOME"
cleanup() {
  kubectl delete crd pizzas.container.training --ignore-not-found --wait=false >/dev/null 2>&1
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
# run BLOCK: as the reader copies it, without the list indentation (the heredoc needs it).
run() { bash -ec "$(dedent <<<"$1")" 2>&1; }
dedent() { awk 'NF{m=match($0,/[^ ]/)-1; if(min==""||m<min)min=m} {l[NR]=$0} END{for(i=1;i<=NR;i++)print substr(l[i],min+1)}'; }
git clone -q https://github.com/jpetazzo/container.training
git -C container.training checkout -q 565636291ec03abf1f2ab8bf6b935478e00e69a2

section "First slice of pizza"
check_output "the inline YAML is k8s/pizza-1.yaml" '^$' bash -c "diff <(printf '%s\n' \"\$1\") container.training/k8s/pizza-1.yaml || true" _ "$(note_block "$NOTE" 2)"
check_output "apiextensions.k8s.io/v1beta1 is gone (from the note)" 'no matches for kind "CustomResourceDefinition" in version "apiextensions.k8s.io/v1beta1"' \
  bash -c "kubectl apply -f container.training/k8s/pizza-1.yaml 2>&1; true"

section "Second slice of pizza"
check_output "the inline YAML is k8s/pizza-2.yaml" '^$' bash -c "diff <(printf '%s\n' \"\$1\") container.training/k8s/pizza-2.yaml || true" _ "$(note_block "$NOTE" 3)"
check_output "spec.versions[].schema.openAPIV3Schema is required (from the note)" 'schema.openAPIV3Schema: Required value' bash -c \
  "sed '/schema:/,\$d' container.training/k8s/pizza-2.yaml | kubectl apply --dry-run=server -f - 2>&1; true"
check_output "exactly one version with storage: true (from the note)" 'must have exactly one version marked as storage version' bash -c \
  "sed 's/storage: true/storage: false/' container.training/k8s/pizza-2.yaml | kubectl apply --dry-run=server -f - 2>&1; true"
check "load the CRD (from the note)" run "$(note_block "$NOTE" 4)"
kubectl wait --for=condition=Established crd/pizzas.container.training --timeout=60s >/dev/null
check_output "it shows up (from the note)" '^pizzas.container.training ' run "$(note_block "$NOTE" 5)"

section "Creating custom resources"
check_output "with the trivial schema, unknown fields are errors (from the note)" 'strict decoding error: unknown field "spec"' \
  bash -c "$(note_block "$NOTE" 7) 2>&1; true"
check "a bland pizza works (from the note)" run "$(note_block "$NOTE" 8)"

section "Third slice of pizza"
check "pizza-3.yaml (from the note)" run "$(note_block "$NOTE" 9)"
check "the recipes load now (from the note)" run "$(note_block "$NOTE" 10)"
check_output "kubectl get pizzas: only name and age (from the note)" '^NAME +AGE$' bash -c "$(note_block "$NOTE" 11) | head -1"

section "Additional printer columns"
check "pizza-4.yaml (from the note)" run "$(note_block "$NOTE" 13)"
check_output "the CRD has the note's printer columns" '^\.spec\.sauce Sauce string \.spec\.toppings Toppings string $' bash -c \
  "kubectl get crd pizzas.container.training -o jsonpath='{range .spec.versions[0].additionalPrinterColumns[*]}{.jsonPath} {.name} {.type} {end}'"
check_output "kubectl get pizzas shows them (and AGE is gone)" '^NAME +SAUCE +TOPPINGS$' bash -c "$(note_block "$NOTE" 14) | head -1"
check_output "margherita: red, [\"mozarella\",\"basil\"]" '^margherita +red +\["mozarella","basil"\]$' bash -c "kubectl get pizzas | grep margherita"

section "Validation woes"
out=$(bash -c "$(note_block "$NOTE" 15) 2>&1; true")
check_output "the label works for the pizzas with sauce and toppings (from the note)" 'pizza.container.training/margherita labeled' echo "$out"
check_output "but not the bland one: it fails validation (from the note)" 'hawaiian.*spec: Required value' echo "$out"
check "option 1: delete it, deletion is not validated (from the note)" kubectl delete pizza hawaiian

section "Validation ratcheting"
check_output "pizza-5.yaml adds the enum" 'enum: \[ red, white \]' cat container.training/k8s/pizza-5.yaml
check "pizza-5.yaml (from the note)" run "$(note_block "$NOTE" 16)"
check_output "a new chocolate pizza is refused" 'Unsupported value: "chocolate"' bash -c \
  "kubectl get pizza brownie -o json | jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp) | .metadata.name=\"brownie2\"' | kubectl create -f - 2>&1; true"
check_output "but ratcheting lets the label through: the sauce did not change (from the note)" 'pizza.container.training/brownie labeled' \
  run "$(note_block "$NOTE" 17)"
check_output "(for all four pizzas)" '^4$' bash -c "kubectl get pizzas -l food=definitely --no-headers | wc -l | tr -d ' '"
