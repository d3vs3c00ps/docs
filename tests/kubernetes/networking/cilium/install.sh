#!/usr/bin/env bash
# note: kubernetes/networking/cilium/install.md
# env: kind
# timeout: 2400
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
source "$NOTES_ROOT/tests/kubernetes/networking/cilium/cilium-lib.bash"

NOTE=kubernetes/networking/cilium/install
WORK=$(mktemp -d)
cd "$WORK"
C=cil-install

section "Installing with Helm"
assert_match "the note installs the pinned chart version" "--version $CILIUM_VERSION" \
  "$(note_block "$NOTE" 'Installing with Helm' 1)"
# Install like the note's "typical starting point": kube-proxy replaced. On kind the
# API server is reachable at the control-plane node's name on port 6443.
cilium_cluster "$C" 1 \
  --set kubeProxyReplacement=true \
  --set "k8sServiceHost=$C-control-plane" \
  --set k8sServicePort=6443
check_output "the agent DaemonSet is running on every node" '2 *2 *2' \
  bash -c "kubectl -n kube-system get ds cilium --no-headers | tr -s ' '"

section "Prerequisites"
check_output "the BPF filesystem is mounted on the nodes (from the note)" \
  'bpf on /sys/fs/bpf type bpf' \
  docker exec "$C-control-plane" bash -ec "$(note_block "$NOTE" 'Prerequisites' 1 | sed -n 1p)"

section "Installing with cilium-cli"
# Download and verify the CLI with the note's own block; skip its `cilium install`
# (the chart is already installed) and run its `cilium status --wait`.
cliblock=$(note_block "$NOTE" 'Installing with cilium-cli' 1 | sed '/^cilium install/d; s/^sudo //')
check "the note's download block verifies the checksum and installs the CLI" \
  bash -ec "$cliblock"
check_output "cilium status --wait reports OK" 'OK|Cilium:.*OK' cilium status --wait

section "Removing kube-proxy"
check "delete the kube-proxy DaemonSet and ConfigMap (from the note)" \
  bash -ec "$(note_block "$NOTE" 'Removing kube-proxy' 1 | sed -n 1,2p)"
for n in "$C-control-plane" "$C-worker"; do
  docker exec "$n" sh -c 'iptables-save | grep -v KUBE- | iptables-restore'
done
kubectl create deployment web --image=nginx:1.29 >/dev/null
kubectl expose deployment web --port=80 >/dev/null
kubectl rollout status deployment/web --timeout=180s >/dev/null
check_output "Services still work without kube-proxy (eBPF datapath)" 'Welcome to nginx' \
  kubectl run kpr-probe --image=alpine --restart=Never --rm -i --quiet -- \
  wget -qO- -T 10 http://web

section "Verifying"
check_output "cilium-dbg status --verbose on a node (from the note)" \
  'KubeProxyReplacement: *True' \
  bash -ec "$(note_block "$NOTE" 'Verifying' 2)"
check_output "a pod gets an address and resolves the API service (from the note)" \
  'inet 10\.' bash -ec "$(note_block "$NOTE" 'Verifying' 4)"
# The full run takes ~10 minutes; the no-policies suite covers pod-to-pod,
# pod-to-service and pod-to-world on a healthy datapath.
check "cilium connectivity test (the note's check, no-policies suite)" \
  bash -c 'cilium connectivity test --test no-policies 2>&1 | tail -3'

section "Upgrading"
check "helm upgrade --reuse-values, rollout, status (from the note)" \
  bash -ec "$(note_block "$NOTE" 'Upgrading' 1 | grep -v '^#')"
