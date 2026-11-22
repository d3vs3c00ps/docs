#!/usr/bin/env bash
# note: kubernetes/workloads/labels-annotations.md
# env: kind
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/workloads/labels-annotations
cd "$(mktemp -d)"
# Docker Hub limits anonymous pulls per IP, and every test shares this IP.
# mirror.gcr.io serves the same Docker Hub images.
mirror() { sed -E 's#(--image[= ])jpetazzo/#\1mirror.gcr.io/jpetazzo/#g'; }
run_block() { bash -ec "$(note_block "$NOTE" "$1" "${2:-1}" | mirror)"; }

section "Viewing labels and annotations"
check "kubectl create deployment clock (from the note)" run_block 'Viewing labels and annotations' 1
kubectl rollout status deployment clock --timeout=180s >/dev/null
describe=$(run_block 'Viewing labels and annotations' 2)

section "Labels and annotations for our Deployment"
assert_match "one label: app=clock" '^Labels: +app=clock$' "$describe"
assert_match "one annotation: deployment.kubernetes.io/revision: 1" \
  '^Annotations: +deployment.kubernetes.io/revision: 1$' "$describe"
assert_eq "and no other annotation" 1 \
  "$(kubectl get deployment clock -o json | jq '.metadata.annotations | length')"

section "And for the related Pod?"
pod=$(kubectl get pods -l app=clock -o name | sed -n 1p)
check_output "kubectl get pods lists clock-xxxxxxxxxx-yyyyy (from the note)" \
  '^clock-[a-z0-9]+-[a-z0-9]{5} ' bash -ec "$(note_block "$NOTE" 'And for the related Pod?' 1)"
pdescribe=$(note_block "$NOTE" 'And for the related Pod?' 2 | sed "s|clock-xxxxxxxxxx-yyyyy|${pod#pod/}|" | bash -e)

section "Labels and annotations for our Pod"
assert_match "two labels: app=clock and pod-template-hash" \
  'Labels: +app=clock +pod-template-hash=[a-z0-9]+ +Annotations' "$(tr -s '\n' ' ' <<<"$pdescribe")"
hash=$(kubectl get "$pod" -o jsonpath='{.metadata.labels.pod-template-hash}')
check_output "pod-template-hash is the ReplicaSet's hash" "^clock-$hash\$" \
  kubectl get "$pod" -o jsonpath='{.metadata.ownerReferences[0].name}'
assert_match "no annotations" '^Annotations: +<none>$' "$pdescribe"

section "Selectors"
kubectl run other --image=registry.k8s.io/pause:3.10 --labels=app=other >/dev/null
check_output "--selector=app=clock lists only clock Pods (from the note)" '^clock-[^ ]+$' \
  bash -ec "$(note_block "$NOTE" Selectors 1) -o name | sed 's|pod/||'"
check_output "--selector=app lists Pods with any app value (from the note)" '^clock-[^ ]+ other $' \
  bash -ec "$(note_block "$NOTE" Selectors 2) -o name | sed 's|pod/||' | sort | tr '\\n' ' '"

section "Setting labels and annotations"
check "kubectl label deployment clock color=blue (from the note)" run_block 'Setting labels and annotations' 1
check_output "describe shows the new label (from the note)" 'color=blue' run_block 'Setting labels and annotations' 2
check "kubectl annotate, then remove the label (from the note)" run_block 'Setting labels and annotations' 3
check_output "the annotation is set" '^the clock team$' \
  kubectl get deployment clock -o jsonpath='{.metadata.annotations.owner}'
check_output "the label is gone" '^$' kubectl get deployment clock -o jsonpath='{.metadata.labels.color}'

section "Other ways to view labels"
check_output "--show-labels (from the note)" 'app=clock,pod-template-hash=' run_block 'Other ways to view labels' 1
check_output "-L app adds an APP column (from the note)" ' APP .* clock $' \
  bash -ec "$(note_block "$NOTE" 'Other ways to view labels' 2) -l app=clock | tr '\\n' ' '"
check_output "-l is short for --selector" '^pod/clock-' kubectl get pods -l app=clock -o name
check_output "several labels: match at least all of them" '^pod/clock-' \
  kubectl get pods -l "app=clock,pod-template-hash=$hash" -o name
check_output "a negative selector" '^pod/other$' kubectl get pods --selector='app!=clock' -o name
kubectl label pods -l app=clock tier=demo >/dev/null
check_output "kubectl label accepts a selector" '^demo$' kubectl get "$pod" -o jsonpath='{.metadata.labels.tier}'

section "Labels on several kinds of objects"
check_output "kubectl get --show-labels po,rs,deploy,svc,no (from the note)" \
  'deployment.apps/clock .*app=clock' run_block 'Labels on several kinds of objects' 1

section "Differences between labels and annotations"
n63=$(printf 'a%.0s' {1..63})
prefix=$(printf 'a%.0s' {1..63}).$(printf 'b%.0s' {1..63}).$(printf 'c%.0s' {1..63}).$(printf 'd%.0s' {1..61})
check "a 63-character name is accepted" kubectl label deployment clock "$n63=x"
check_fails "a 64-character name is rejected" kubectl label deployment clock "${n63}b=x"
check "a 253-character prefix + / + 63 is accepted" kubectl label deployment clock "$prefix/$n63=x"
check_fails "a 254-character prefix is rejected" kubectl label deployment clock "e$prefix/$n63=x"
check_fails "an uppercase prefix is rejected" kubectl label deployment clock "Example.com/k=x"
check_fails "a name cannot start with -" kubectl label deployment clock "-k=x"
check "a name can have . - _ inside" kubectl label deployment clock "a.b-c_d=x"
check "a 63-character label value is accepted" kubectl label deployment clock "v=$n63"
check_fails "a 64-character label value is rejected" kubectl label deployment clock --overwrite "v=${n63}b"
check "an empty label value is accepted" kubectl label deployment clock --overwrite "v="
check "an annotation value can be any string" kubectl annotate deployment clock 'note=Hello, world! {"json": true}'
big_annotation() { python3 -c "import json,sys; print(json.dumps({'metadata': {'annotations': {'big': 'x' * int(sys.argv[1])}}}))" "$1" >big.json; kubectl patch deployment clock --type=merge --patch-file big.json; }
export -f big_annotation
check "a 50 KB annotation is fine" big_annotation 50000
check_output "more than 256 KiB of annotations is rejected" 'annotations: Too long: .*262144 bytes' \
  bash -c 'big_annotation 270000 2>&1; true'
