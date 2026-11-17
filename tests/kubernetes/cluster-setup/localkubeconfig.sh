#!/usr/bin/env bash
# note: kubernetes/cluster-setup/localkubeconfig.md
# env: kind
# timeout: 600
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/cluster-setup/localkubeconfig
CP=$CLUSTER-control-plane
# A fresh HOME is "our local machine"; the kind control plane is node1.
SHARED_KUBECONFIG=$KUBECONFIG
HOME=$(mktemp -d)
export HOME
unset KUBECONFIG
cd "$HOME"
mkdir -p .kube
run() { bash -ec "$1" 2>&1; }
rejected() { "$@" || true; }

section "Installing kubectl"
arch=$(uname -m)
case $arch in aarch64) arch=arm64 ;; x86_64) arch=amd64 ;; esac
check_output "the note's old download host still redirects" '^(200|302)$' \
  curl -s -o /dev/null -w '%{http_code}' "https://storage.googleapis.com/kubernetes-release/release/stable.txt"
check "the note's current link (dl.k8s.io) downloads kubectl for this machine" bash -ec \
  "curl -fsSLo kubectl https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$arch/kubectl && chmod +x kubectl && ./kubectl version --client"

section "Testing kubectl"
check_output "kubectl version --client (from the note): the current output format" \
  "^Client Version: $KUBECTL_VERSION\$" run "$(note_block "$NOTE" 'Testing `kubectl`' 1)"
assert_eq "the note's sample output is what this kubectl prints" \
  "$(kubectl version --client)" "$(note_block "$NOTE" 'Testing `kubectl`' 2)"

section "Preserving the existing ~/.kube/config"
echo 'previous: config' >.kube/config
check "make a copy (from the note)" run "$(note_block "$NOTE" 'Preserving' 1)"
check_output "the copy is there" 'previous: config' cat .kube/config.before.training

section "Copying the configuration file from node1"
# The note uses scp; the kind node is a container.
docker exec "$CP" cat /etc/kubernetes/admin.conf >.kube/config
# kind sets kubeadm's clusterName to the kind cluster name; kubeadm's default is kubernetes.
sed -i "s/^  name: $CLUSTER\$/  name: kubernetes/; s/^    cluster: $CLUSTER\$/    cluster: kubernetes/" .kube/config
check_output "the node's file names the cluster kubernetes" '^kubernetes$' \
  kubectl config view -o jsonpath='{.clusters[0].name}'
check_output "its server is an address only the nodes reach" "^https://$CP:6443\$" \
  kubectl config view -o jsonpath='{.clusters[0].cluster.server}'

section "Updating the server address"
PORT=$(docker port "$CP" 6443/tcp | sed -n 's/^127\.0\.0\.1:\([0-9]*\)$/\1/p' | head -1)
setc=$(note_block "$NOTE" 'Updating the server address' 1 | sed '/^#/d')
check "kubectl config set-cluster --server (from the note)" run "${setc/X.X.X.X/127.0.0.1}"
sed -i "s|https://127.0.0.1:6443|https://127.0.0.1:$PORT|" .kube/config
check_output "now we reach the cluster" "$CP +Ready" kubectl get nodes

section "What if we get a certificate error?"
SANS=$(docker exec "$CP" openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -ext subjectAltName)
for san in DNS:kubernetes DNS:kubernetes.default DNS:kubernetes.default.svc DNS:kubernetes.default.svc.cluster.local \
  IP\ Address:10.96.0.1 "DNS:$CP"; do
  assert_match "the API server certificate is valid for $san" "$san(,|$)" "$SANS"
done
assert_match "and for the node's IP address" \
  "IP Address:$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CP")" "$SANS"
# localtest.me resolves to 127.0.0.1, but is not in the certificate: like an external IP.
kubectl config set-cluster kubernetes --server="https://localtest.me:$PORT" >/dev/null
check_output "another name or address: the certificate error" 'x509: certificate is valid for' \
  rejected kubectl get nodes

section "Working around the certificate error"
check "set-cluster --insecure-skip-tls-verify (from the note)" run "$(note_block "$NOTE" 'Working around' 1)"
check_output "it connects, without checking the certificate (kubectl 1.37 accepts it next to the CA data)" \
  "$CP +Ready" kubectl get nodes

section "Checking that we can connect to the cluster"
check_output "kubectl version shows client and server (from the note)" '^Server Version: v1\.' \
  run "$(note_block "$NOTE" 'Checking that we can connect' 1)"
check_output "kubectl get nodes (from the note)" "$CP +Ready" run "$(note_block "$NOTE" 'Checking that we can connect' 2)"
export KUBECONFIG=$SHARED_KUBECONFIG
