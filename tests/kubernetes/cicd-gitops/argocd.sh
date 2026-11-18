#!/usr/bin/env bash
# note: kubernetes/cicd-gitops/argocd.md
# env: kind
# timeout: 2400
# The CLI part of the note, with the upstream jpetazzo/kubercoins repository in place
# of a fork. Own cluster: Argo CD and its CRDs are cluster-wide.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/cicd-gitops/argocd
HOME=$(mktemp -d)
export HOME
cd "$HOME"
C=notes-argocd
kind_cluster "$C"
printf 'kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nnodes: [{role: control-plane}, {role: worker}]\n' >kind.yaml
out=$(kind create cluster --name "$C" --image "$KIND_NODE_IMAGE" --config kind.yaml 2>&1) || { echo "$out"; kind_diag; exit 1; }
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
trap '_k8s_rc=$?; kill %1 2>/dev/null || true; _k8s_exit' EXIT
run() { bash -ec "$1" 2>&1; }
arch=$(uname -m)
case $arch in aarch64) arch=arm64 ;; x86_64) arch=amd64 ;; esac
mkdir -p bin
export PATH=$HOME/bin:$PATH
# dedent: remove the smallest common indentation (the note's blocks are inside lists).
dedent() { awk 'NF{m=match($0,/[^ ]/)-1; if(min==""||m<min)min=m} {l[NR]=$0} END{for(i=1;i<=NR;i++)print substr(l[i],min+1)}'; }

section "Getting ready"
check "the ArgoCD CLI, from the binary releases" bash -ec \
  "curl -fsSLo bin/argocd https://github.com/argoproj/argo-cd/releases/download/$ARGOCD_VERSION/argocd-linux-$arch; chmod +x bin/argocd"

section "Setting up ArgoCD"
install=$(note_block "$NOTE" 1)
assert_match "the note pins the tested version" "argo-cd/$ARGOCD_VERSION/manifests" "$install"
check "kubectl create namespace, and the upstream manifests (from the note)" run "$install"
check_output "(kubectl apply would fail: a CRD is too big for its annotation)" 'Too long|too long' bash -c \
  "kubectl apply --dry-run=server -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml 2>&1; true"
kubectl -n argocd wait deploy --all --for=condition=Available --timeout=600s >/dev/null
kubectl -n argocd rollout status sts/argocd-application-controller --timeout=300s >/dev/null

section "Logging in with the ArgoCD CLI"
check "argocd login --core (from the note)" run "$(note_block "$NOTE" 2)"
check_output "argocd version, outside the argocd namespace: argocd-cm not found (from the note)" \
  '"level":"fatal","msg":"configmap \\"argocd-cm\\" not found"' bash -c "$(note_block "$NOTE" 3) 2>&1; true"
check "switch to the argocd namespace (from the note)" run "$(note_block "$NOTE" 4)"
check_output "argocd version now works (from the note)" "argocd-server: v${ARGOCD_VERSION#v}" run "$(note_block "$NOTE" 5)"

section "Add an Application"
create=$(note_block "$NOTE" 6 | sed 's|<your_user>/<your_repo>|jpetazzo/kubercoins|; s|<branch>|master|')
check "argocd app create kubercoins (from the note, with the upstream repository)" run "$create"
retry 120 bash -c "kubectl get application kubercoins -o jsonpath='{.status.sync.status}' | grep -q OutOfSync"
check_output "argocd app list: OutOfSync (from the note)" '^(argocd/)?kubercoins +.*OutOfSync' run "$(note_block "$NOTE" 7)"
check_output "kubectl get applications (from the note)" '^kubercoins +OutOfSync' run "$(note_block "$NOTE" 8)"

section "Manual sync with the CLI"
check_output "auto sync looks every 120s, plus up to 60s of jitter: 3 minutes at most (from the note)" \
  '--app-resync int .*\(default 120\).*--app-resync-jitter int .*\(default 60\)' bash -c \
  "kubectl exec sts/argocd-application-controller -- argocd-application-controller --help | grep -E -- '--app-resync(-jitter)? int' | tr '\n' ' '"
out=$(bash -c "$(note_block "$NOTE" 9) 2>&1; true")
check_output "argocd app sync: Failed (from the note)" 'Operation has completed with phase: Failed' echo "$out"
check_output "because the namespace does not exist (from the note)" 'namespaces "kubercoins-prod" not found' echo "$out"

section "Editing the app's sync options"
note_block "$NOTE" 11 | dedent >syncpolicy.yaml
printf '#!/bin/sh\ncat %s >>"$1"\n' "$HOME/syncpolicy.yaml" >bin/append-syncpolicy
chmod +x bin/append-syncpolicy
check "argocd app edit, adding syncPolicy at the root level (from the note)" \
  env EDITOR=append-syncpolicy bash -ec "$(note_block "$NOTE" 10)"
check_output "the Application has the sync option" 'CreateNamespace=true' \
  kubectl get application kubercoins -o jsonpath='{.spec.syncPolicy.syncOptions}'

section "Sync again"
check "argocd app sync (from the note)" run "$(note_block "$NOTE" 12)"
check_output "Synced (from the note)" '^kubercoins +Synced' kubectl get applications kubercoins
check "and Healthy after a while (from the note)" argocd app wait kubercoins --health --timeout 600
check_output "argocd app list (from the note)" '^(argocd/)?kubercoins +.* Synced +Healthy' run "$(note_block "$NOTE" 13)"

section "Managing Applications via the Web UI"
DPORT=$((20000 + RANDOM % 20000))
argocd admin dashboard --port "$DPORT" >dashboard.log 2>&1 &
check "argocd admin dashboard serves the UI on a local port (from the note)" retry 60 curl -sf "localhost:$DPORT/"
check_output "and the API, with no login (from the note)" '"name":"kubercoins"' \
  curl -s "localhost:$DPORT/api/v1/applications"

section "Creating a Helm Application"
check "argocd app create hasher, with --values ../values/hasher.yaml (from the note)" run "$(note_block "$NOTE" 17)"
check "auto sync: it becomes Synced and Healthy" argocd app wait hasher --sync --health --timeout 600
check_output "the hasher Deployment runs in kubercoins-helm" '^hasher$' \
  kubectl -n kubercoins-helm get deploy -o jsonpath='{.items[*].metadata.name}'
