#!/usr/bin/env bash
# note: kubernetes/cicd-gitops/argocd-advanced.md
# env: kind
# timeout: 1500
# The ApplicationSet example, on Argo CD installed as in kubernetes/cicd-gitops/argocd.
# The example's repositories do not exist: the test checks the generated Applications.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/cicd-gitops/argocd-advanced
cd "$(mktemp -d)"
C=notes-argocd2
kind_cluster "$C"
kind create cluster --name "$C" --image "$KIND_NODE_IMAGE" >/dev/null 2>&1
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
check "Argo CD, installed as in its note" bash -ec "$(note_block kubernetes/cicd-gitops/argocd 1)"
kubectl -n argocd wait deploy --all --for=condition=Available --timeout=600s >/dev/null

section "Application Sets"
appset=$(note_block "$NOTE" 1)
check "the example ApplicationSet (from the note)" bash -c "printf '%s\n' \"\$1\" | kubectl -n argocd apply -f -" _ "$appset"
check "the controller generates one Application per list element" retry 120 bash -c \
  "[ \"\$(kubectl -n argocd get applications -o name | sort | tr '\n' ' ')\" = 'application.argoproj.io/backend application.argoproj.io/frontend ' ]"
check_output "the Go template fills repoURL and namespace (from the note)" \
  '^https://github.com/my-org/frontend.git frontend$' \
  kubectl -n argocd get application frontend -o jsonpath='{.spec.source.repoURL} {.spec.destination.namespace}'
check_output "the Applications belong to the ApplicationSet" '^ApplicationSet my-appset$' \
  kubectl -n argocd get application frontend -o jsonpath='{.metadata.ownerReferences[0].kind} {.metadata.ownerReferences[0].name}'

section "missingkey=error"
bad=$(printf '%s\n' "$appset" | sed 's/name: my-appset/name: bad-appset/; s/- repo: backend/- repository: backend/')
printf '%s\n' "$bad" | kubectl -n argocd apply -f - >/dev/null
retry 60 bash -c "kubectl -n argocd get applicationset bad-appset -o jsonpath='{.status.conditions}' | grep -q 'map has no entry'"
check_output "an element without the repo key is an error, not an empty string" 'map has no entry for key .?"repo' \
  kubectl -n argocd get applicationset bad-appset -o jsonpath='{.status.conditions}'

section "Some generators"
gens=$(kubectl get crd applicationsets.argoproj.io -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.generators.items.properties}' | jq -r 'keys[]')
listed=$(sed -n '/^## Some generators/,/^## /p' "$NOTES_ROOT/content/$NOTE.md" | grep -o '^- `[a-zA-Z]*`' | sed 's/^- `//; s/`$//')
check_output "the note lists seven generators" '^7$' bash -c "wc -l <<<\"\$1\" | tr -d ' '" _ "$listed"
for g in $listed; do
  assert_match "the generator key $g exists (from the note)" "^$g$" "$gens"
done
