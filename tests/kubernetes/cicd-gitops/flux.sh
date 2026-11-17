#!/usr/bin/env bash
# note: kubernetes/cicd-gitops/flux.md
# env: kind
# timeout: 2700
# flux bootstrap github needs a GitHub token. The test writes the same files that
# bootstrap writes, to a Git server (sshd) in a pod. The runner pushes through
# kubectl exec; Flux pulls over SSH. Own cluster: Flux and its CRDs are cluster-wide.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/cicd-gitops/flux
HOME=$(mktemp -d)
export HOME
cd "$HOME"
C=notes-flux
kind_cluster "$C"
printf 'kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nnodes: [{role: control-plane}, {role: worker}]\n' >kind.yaml
kind create cluster --name "$C" --image "$KIND_NODE_IMAGE" --config kind.yaml >/dev/null 2>&1
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
run() { bash -ec "$1" 2>&1; }
export -f retry
arch=$(uname -m)
case $arch in aarch64) arch=arm64 ;; x86_64) arch=amd64 ;; esac
mkdir -p bin
export PATH=$HOME/bin:$PATH
git config --global user.email test@example.com
git config --global user.name test
git config --global init.defaultBranch main
git config --global protocol.ext.allow always
URL=ssh://git@git.git.svc.cluster.local/srv/repo.git
# push MSG: commit everything in the repo and push it, then make Flux look now.
push() {
  git -C "$HOME/repo" add -A
  git -C "$HOME/repo" commit -qm "$1"
  git -C "$HOME/repo" push -q origin main 2>&1
  flux reconcile source git flux-system >/dev/null 2>&1 || true
}
# ready KIND NAME [NS]: wait for a Flux object to be Ready.
ready() { kubectl -n "${3:-flux-system}" wait "$1/$2" --for=condition=Ready --timeout="${4:-300s}" >/dev/null 2>&1; }
# link PATH: add a resource line to the top-level kustomization, as the note says.
link() { printf -- '- %s\n' "$1" >>"$HOME/repo/clusters/dev/flux-system/kustomization.yaml"; }

section "Getting ready"
check "the Flux CLI, from the binary releases (from the note)" bash -ec \
  "curl -fsSL https://github.com/fluxcd/flux2/releases/download/$FLUX_VERSION/flux_${FLUX_VERSION#v}_linux_$arch.tar.gz | tar -xz -C bin flux"
check_output "flux version --client" "flux: ${FLUX_VERSION}" flux version --client
check "flux check --pre: the cluster is good for Flux" flux check --pre

section "A Git server, in place of GitHub"
kubectl create namespace git >/dev/null
kubectl -n git apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: git}
spec:
  selector: {matchLabels: {app: git}}
  template:
    metadata: {labels: {app: git}}
    spec:
      containers:
      - name: sshd
        image: alpine:3.22
        command: [sh, -ec]
        args:
        - |
          apk add --no-cache openssh git >/dev/null
          ssh-keygen -A
          adduser -D -s /usr/bin/git-shell git
          sed -i 's/^git:!/git:*/' /etc/shadow
          mkdir -p /home/git/.ssh
          ssh-keygen -q -t ed25519 -N '' -f /srv/id
          cp /srv/id.pub /home/git/.ssh/authorized_keys
          chown -R git /home/git/.ssh
          git init -q --bare -b main /srv/repo.git
          touch /srv/ready
          exec /usr/sbin/sshd -D -e
        readinessProbe: {exec: {command: [test, -f, /srv/ready]}}
---
apiVersion: v1
kind: Service
metadata: {name: git}
spec:
  selector: {app: git}
  ports: [{port: 22}]
EOF
kubectl -n git rollout status deploy/git --timeout=300s >/dev/null
kubectl -n git exec deploy/git -- cat /srv/id >id
kubectl -n git exec deploy/git -- cat /srv/id.pub >id.pub
hostkey=$(kubectl -n git exec deploy/git -- cat /etc/ssh/ssh_host_ed25519_key.pub | cut -d' ' -f1,2)
git init -q repo
git -C repo remote add origin "ext::kubectl -n git exec -i deploy/git -- %S /srv/repo.git"

section "Flux bootstrap (emulated)"
check_output "flux bootstrap github defaults to a 1 minute Git interval (from the note)" '--interval duration .*\(default 1m0s\)' \
  flux bootstrap github --help
mkdir -p repo/clusters/dev/flux-system
cd repo/clusters/dev/flux-system
flux install --export >gotk-components.yaml
{
  flux create source git flux-system --url="$URL" --branch=main --secret-ref=flux-system --interval=1m --export
  flux create kustomization flux-system --source=GitRepository/flux-system --path=./clusters/dev --prune=true --interval=10m --export
} >gotk-sync.yaml
printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n- gotk-components.yaml\n- gotk-sync.yaml\n' >kustomization.yaml
cd "$HOME"
push "flux bootstrap" >/dev/null
check "install the Flux controllers" kubectl apply -f repo/clusters/dev/flux-system/gotk-components.yaml
kubectl -n flux-system wait deploy --all --for=condition=Available --timeout=300s >/dev/null
kubectl -n flux-system create secret generic flux-system --from-file=identity=id --from-file=identity.pub=id.pub \
  --from-literal=known_hosts="git.git.svc.cluster.local $hostkey" >/dev/null
check "and the sync objects" kubectl apply -f repo/clusters/dev/flux-system/gotk-sync.yaml
check "Flux pulls the repository over SSH" ready gitrepository flux-system
check "and applies clusters/dev, including Flux itself" ready kustomization flux-system

section "What do we get?"
check_output "kubectl get all --namespace flux-system: the four controllers (from the note)" \
  'deployment.apps/helm-controller.*deployment.apps/kustomize-controller.*deployment.apps/notification-controller.*deployment.apps/source-controller' \
  bash -c "$(note_block "$NOTE" 5) | tr '\n' ' '"
check_output "kubectl get kustomizations --all-namespaces (from the note)" '^flux-system +flux-system +.*True' run "$(note_block "$NOTE" 6)"
check_output "flux get all (from the note)" 'gitrepository/flux-system.*main@sha1:' run "$(note_block "$NOTE" 7)"

section "Deploying with GitOps, and namespaces"
kubectl create deployment blue --image=jpetazzo/color --dry-run=client -o yaml >repo/clusters/dev/flux-system/blue.yaml
link blue.yaml
push "blue, no namespace" >/dev/null
retry 120 bash -c "kubectl -n flux-system get kustomization flux-system -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].message}' | grep -q namespace"
check_output "did it work? No: the manifest has no namespace (from the note)" 'namespace' \
  kubectl -n flux-system get kustomization flux-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}'
sed -i 's/^  name: blue$/  name: blue\n  namespace: default/' repo/clusters/dev/flux-system/blue.yaml
push "blue, with a namespace" >/dev/null
check "with the namespace in the manifest, Flux deploys it" retry 180 kubectl -n default rollout status deploy/blue --timeout=5s

section "Adding an app in a reusable way"
git clone -q --depth 1 https://github.com/jpetazzo/container.training
cd repo
check "put the app manifests in their directory (from the note)" run "$(note_block "$NOTE" 8)"
check "flux create kustomization ... --export (from the note)" run "$(note_block "$NOTE" 9)"
check "append the target namespace (from the note)" run "$(note_block "$NOTE" 10)"
check "the result is valid YAML for the API server" kubectl apply --dry-run=server -f apps/dockercoins/flux.yaml
cd "$HOME"
link "$(note_block "$NOTE" 11 | sed 's/^ *- //')"
push "dockercoins" >/dev/null
check "Flux creates the dockercoins Kustomization" retry 120 kubectl -n flux-system get kustomization dockercoins
check "and it becomes Ready" ready kustomization dockercoins flux-system 600s
check_output "DockerCoins runs in the target namespace" '^5$' bash -c \
  "kubectl -n dockercoins get deploy -o name | wc -l | tr -d ' '"

section "Installing from a public Helm repository"
cd repo
check "flux create source helm / helmrelease --export (from the note)" run "$(note_block "$NOTE" 12)"
assert_match "the note pins the tested chart" "--chart-version=$KUBE_PROMETHEUS_STACK_CHART" "$(note_block "$NOTE" 12)"
cd "$HOME"
link ../../../apps/kube-prometheus-stack/flux.yaml
push "kube-prometheus-stack" >/dev/null
check "the HelmRelease becomes Ready" bash -c \
  "retry 120 kubectl -n flux-system get helmrelease kube-prometheus-stack && kubectl -n flux-system wait helmrelease/kube-prometheus-stack --for=condition=Ready --timeout=900s"
check_output "Prometheus and Grafana run (from the note)" 'grafana.*prometheus' bash -c \
  "kubectl -n kube-prometheus-stack get deploy,sts -o name | sort | tr '\n' ' '"

section "Installing from a Helm chart in a git repo"
cd repo
check "helm create charts/myapp (from the note)" run "$(note_block "$NOTE" 13)"
check "flux create helmrelease myapp ... --export (from the note)" run "$(note_block "$NOTE" 14)"
cd "$HOME"
link ../../../apps/myapp/flux.yaml
push "myapp" >/dev/null
check "the myapp HelmRelease becomes Ready" bash -c \
  "retry 120 kubectl -n flux-system get helmrelease myapp && kubectl -n flux-system wait helmrelease/myapp --for=condition=Ready --timeout=600s"
check_output "the chart's NGINX runs in namespace myapp" '^1$' kubectl -n myapp get deploy -o jsonpath='{.items[0].status.readyReplicas}'

section "Passing values"
check_output "flux create helmrelease has --values and --values-from (from the note)" '--values-from.*--values ' \
  bash -c "flux create helmrelease --help | grep -E -- '--values(-from)? ' | sort -r | tr '\n' ' '"

section "Gotchas: reconcileStrategy"
check_output "the default strategy is ChartVersion (from the note)" '^ChartVersion$' \
  kubectl -n flux-system get helmchart flux-system-myapp -o jsonpath='{.spec.reconcileStrategy}'
sed -i 's/^replicaCount: 1$/replicaCount: 2/' repo/charts/myapp/values.yaml
push "myapp: 2 replicas, same chart version" >/dev/null
flux reconcile helmrelease myapp --with-source >/dev/null 2>&1 || true
sleep 30
check_output "a chart change without a version bump is not deployed (from the note)" '^1$' \
  kubectl -n myapp get deploy -o jsonpath='{.items[0].spec.replicas}'
sed -i 's/reconcileStrategy: ChartVersion/reconcileStrategy: Revision/' repo/apps/myapp/flux.yaml
grep -q 'reconcileStrategy: Revision' repo/apps/myapp/flux.yaml ||
  sed -i 's/^      chart: charts\/myapp$/      chart: charts\/myapp\n      reconcileStrategy: Revision/' repo/apps/myapp/flux.yaml
push "myapp: reconcileStrategy Revision" >/dev/null
flux reconcile kustomization flux-system >/dev/null 2>&1 || true
check "with reconcileStrategy: Revision, it is (from the note)" retry 300 bash -c \
  "flux reconcile helmrelease myapp --with-source >/dev/null 2>&1; [ \"\$(kubectl -n myapp get deploy -o jsonpath='{.items[0].spec.replicas}')\" = 2 ]"
