#!/usr/bin/env bash
# note: security/neuvector.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=security/neuvector
block() { note_block "$NOTE" "$@"; }
case $(uname -m) in x86_64) a=amd64 ;; aarch64) a=arm64 ;; esac
curl -fsSL --retry 5 "https://get.helm.sh/helm-$HELM_VERSION-linux-$a.tar.gz" | tar -xz --strip-components=1 -C /usr/local/bin "linux-$a/helm"
curl -fsSL --retry 5 -o /usr/local/bin/kubectl "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$a/kubectl"
chmod +x /usr/local/bin/kubectl
cd "$(mktemp -d)"
# The chart is rendered offline. Running NeuVector needs a privileged enforcer on every
# node, which on a shared kind cluster would watch every other test's containers.

section "Installation"
inst=$(block Installation 1)
check "helm repo add and update (from the note)" bash -ec "$(sed -n 1,2p <<<"$inst")"
check_output "the core chart is in the repo" 'neuvector/core' helm search repo neuvector/core
check_output "the namespace and its Pod Security label (from the note, client dry run)" \
  'pod-security.kubernetes.io/enforce: privileged' \
  bash -c "kubectl create namespace neuvector --dry-run=client -o yaml | kubectl label --local -f - pod-security.kubernetes.io/enforce=privileged -o yaml"
helm template neuvector neuvector/core --namespace neuvector >rendered.yaml
check "helm template renders the note's install" test -s rendered.yaml
check_output "the enforcer is a DaemonSet" '^neuvector-enforcer-pod$' \
  bash -c "awk '/^kind: DaemonSet/{d=1} d && /^  name:/{print \$2; d=0}' rendered.yaml"
check_output "and it runs privileged (why the label is needed)" 'privileged: true' \
  bash -c "awk '/^kind: DaemonSet/,/^---/' rendered.yaml"

section "Reaching the console"
svc() { awk '/^kind: Service$/,/^---/' "$1" | awk '/name: neuvector-service-webui/,/^---/'; }
assert_match "the web UI service is neuvector-service-webui, port 8443 (from the note)" 'port: 8443' "$(svc rendered.yaml)"
assert_match "ClusterIP by default, so port-forward is the way in (the correction)" 'type: ClusterIP' "$(svc rendered.yaml)"
helm template neuvector neuvector/core --namespace neuvector --set manager.svc.type=NodePort >nodeport.yaml
assert_match "--set manager.svc.type=NodePort makes it a NodePort (from the note)" 'type: NodePort' "$(svc nodeport.yaml)"
skip "the console, admin / admin, and the Discover/Monitor/Protect modes" \
  "need NeuVector running on a cluster, with its privileged enforcer on every node"
