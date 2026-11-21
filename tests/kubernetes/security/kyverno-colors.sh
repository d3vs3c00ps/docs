#!/usr/bin/env bash
# note: kubernetes/security/kyverno-colors.md
# env: kind
# timeout: 2400
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
source "$NOTES_ROOT/tests/kubernetes/security/kyverno-lib.bash"

NOTE=kubernetes/security/kyverno-colors
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
use_test_namespace
WORK=$(mktemp -d)
cd "$WORK"
export HOME=$WORK/home
mkdir -p "$HOME/container.training/k8s"
for i in 1 2 3; do
  curl -fsSL "$UPSTREAM/k8s/kyverno-pod-color-$i.yaml" >"$HOME/container.training/k8s/kyverno-pod-color-$i.yaml"
done
cleanup() { kyverno_cleanup; _k8s_exit; }
trap '_k8s_rc=$?; cleanup' EXIT

# "Load and try the policy" appears three times, so blocks are picked by their
# index in the note. b N [LINE]: block N, or only its LINE-th line.
b() { if [[ -n ${2:-} ]]; then note_block "$NOTE" "$1" | sed -n "${2}p"; else note_block "$NOTE" "$1"; fi; }
assert_match "block 3 is the first kubectl run (indexes still match the note)" 'test-color-0' "$(b 3)"
assert_match "block 15 is the last set of label commands" 'test-color-3 color-' "$(b 15)"
run() { bash -ec "$1" 2>&1; }
denied() { ! run "$1" >"$WORK/out" 2>&1 && grep -q 'denied the request\|blocked due to' "$WORK/out"; }
pod() { run "$1" >/dev/null && kubectl wait --for=condition=Ready "pod/$2" --timeout=180s >/dev/null; }

check "Kyverno is installed (as in kubernetes/security/kyverno)" kyverno_install
kyverno_wait

section "Immutable primary colors, take 1"
for i in 1 2 3; do
  assert_eq "policy $i shown in the note is the upstream file" \
    "$(cat "$HOME/container.training/k8s/kyverno-pod-color-$i.yaml")" "$(b $((i == 1 ? 2 : i == 2 ? 8 : 12)))"
done

section "Testing without the policy"
check "create test-color-0 (from the note)" pod "$(b 3)" test-color-0
check "without a policy, color=purple is accepted" run "$(b 4)"

section "Load and try the policy (take 1)"
check "load policy 1 (from the note)" run "$(b 5)"
kubectl wait --for=condition=Ready clusterpolicy/pod-color-policy-1 --timeout=120s >/dev/null
check "create test-color-1" pod "$(b 6)" test-color-1
check "color=purple is denied" denied "$(b 7 1)"
check "color=red is accepted" run "$(b 7 2)"
check "removing the label is still accepted (only take 3 forbids it)" run "$(b 7 3)"

section "Load and try the policy (take 2)"
check "load policy 2 (from the note)" run "$(b 9)"
kubectl wait --for=condition=Ready clusterpolicy/pod-color-policy-2 --timeout=120s >/dev/null
check "create test-color-2" pod "$(b 10)" test-color-2
check "color=purple is denied (policy 1)" denied "$(b 11 1)"
check "color=red is accepted" run "$(b 11 2)"
check "changing it to blue is denied (policy 2)" denied "$(b 11 3)"
assert_match "with the policy's message" 'Once label color has been added, it cannot be changed' "$(cat "$WORK/out")"

section "Load and try the policy (take 3)"
check "load policy 3 (from the note)" run "$(b 13)"
kubectl wait --for=condition=Ready clusterpolicy/pod-color-policy-3 --timeout=120s >/dev/null
check "create test-color-3" pod "$(b 14)" test-color-3
check "color=purple is denied (policy 1)" denied "$(b 15 1)"
check "color=red is accepted" run "$(b 15 2)"
check "removing it is denied (policy 3)" denied "$(b 15 3)"
assert_match "with the policy's message" 'Once label color has been added, it cannot be removed' "$(cat "$WORK/out")"

section "Background checks"
check_output "test-color-0 still has its invalid color (from the note)" 'test-color-0 .* purple' \
  run "$(b 16)"
check "kubectl get policyreports / polr work (from the note)" run "$(b 17)"
check "a PolicyReport shows test-color-0 failing policy 1 (it can take a while)" retry 180 bash -c \
  "kubectl get policyreports -o json | jq -e '[.items[] | select(.scope.name==\"test-color-0\") | .results[]? | select(.policy==\"pod-color-policy-1\" and .result==\"fail\")] | length > 0' >/dev/null"
