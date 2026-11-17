#!/usr/bin/env bash
# note: kubernetes/cluster-setup/kind.md
# env: kind
# timeout: 1800
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/cluster-setup/kind
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
cd "$(mktemp -d)"
# One cluster at a time, named for this test (the note's commands use the default name, kind).
C=notes-kind
kind_cluster "$C"
run() { bash -ec "$1" 2>&1; }
# up CONFIG: a cluster from CONFIG, with the pinned node image.
up() {
  kind delete cluster --name "$C" >/dev/null 2>&1 || true
  kind create cluster --name "$C" --image "$KIND_NODE_IMAGE" --config "$1" 2>&1 &&
    # Pods are refused until the controller manager creates the default ServiceAccount.
    retry 60 kubectl get serviceaccount default
}
retry_curl() {
  local i
  for i in $(seq 1 60); do curl -fsS "$1" 2>/dev/null && return 0; sleep 2; done
  curl -fsS "$1"
}
nginx_nodeport() {
  kubectl create deployment web --image=nginx:1.29 >/dev/null
  kubectl create service nodeport web --tcp=80:80 --node-port="$1" >/dev/null
  kubectl rollout status deployment/web --timeout=180s >/dev/null
}

section "Getting started"
check "kind create cluster (from the note)" run "$(note_block "$NOTE" 1) --name $C --image $KIND_NODE_IMAGE"
check_output "it was added to the kubeconfig" "^kind-$C\$" kubectl config current-context
check_output "see it running with docker ps" "$C-control-plane" docker ps --format '{{.Names}}'
check_output "it is based on kubeadm" 'kubeadm' docker exec "$C-control-plane" ls /kind
check "kind delete cluster (from the note)" run "$(note_block "$NOTE" 2) --name $C"
check_output "it is gone" '^$' bash -c "docker ps --format '{{.Names}}' | grep '^$C-' || true"

section "Customizing the cluster"
note_block "$NOTE" 3 >custom.yaml
assert_match "the note pins a node image per node" 'image: kindest/node:v1\.' "$(cat custom.yaml)"
check "that image tag exists" bash -c "docker manifest inspect $(sed -n 's/^  image: //p' custom.yaml | head -1) >/dev/null"
# Same file, with the image the tests pin (--image overrides it).
check "kind create cluster --config with 2 nodes and a port mapping" up custom.yaml
check_output "1 control plane and 1 worker" '^2$' bash -c 'kubectl get nodes --no-headers | wc -l'
nginx_nodeport 31234
check_output "NodePort 31234 answers on host port 10000" 'Welcome to nginx' \
  retry_curl http://127.0.0.1:10000/

section "Mapping ports 80 and 443"
# The same mappings, to free host ports: 80 and 443 may be taken on the machine running the tests.
note_block "$NOTE" 4 | sed 's/hostPort: 80$/hostPort: 18080/; s/hostPort: 443$/hostPort: 18443/' >np.yaml
check "the NodePort mapping config" up np.yaml
nginx_nodeport 30080
check_output "NodePort 30080 answers on the mapped host port" 'Welcome to nginx' retry_curl http://127.0.0.1:18080/

section "Variation: hostPort"
note_block "$NOTE" 5 | sed 's/hostPort: 80$/hostPort: 18080/; s/hostPort: 443$/hostPort: 18443/' >hp.yaml
check "the hostPort mapping config" up hp.yaml
kubectl run web --image=nginx:1.29 --port=80 \
  --overrides='{"spec":{"containers":[{"name":"web","image":"nginx:1.29","ports":[{"containerPort":80,"hostPort":80}]}]}}' >/dev/null
kubectl wait --for=condition=Ready pod/web --timeout=180s >/dev/null
check_output "a pod with hostPort 80 answers on the mapped host port" 'Welcome to nginx' retry_curl http://127.0.0.1:18080/

section "Mapping a range of ports"
curl -fsSL "$UPSTREAM/k8s/kind-12300.yaml" >range.yaml
check "the upstream file, with extraArgs as a map" up range.yaml
check_output "(the API server got the flag from the map too)" 'service-node-port-range=12301-12309' \
  docker exec "$C-control-plane" cat /etc/kubernetes/manifests/kube-apiserver.yaml
note_block "$NOTE" 6 | grep -v '^  \.\.\.$' >range-fixed.yaml
check "the note's version, with extraArgs as a name/value list" up range-fixed.yaml
check_output "the API server got the flag" 'service-node-port-range=12301-12309' \
  docker exec "$C-control-plane" cat /etc/kubernetes/manifests/kube-apiserver.yaml
check_fails "a NodePort outside the range is refused" kubectl create service nodeport out --tcp=80:80 --node-port=30080
# 12301: the note's excerpt elides the middle mappings ("...").
nginx_nodeport 12301
check_output "a NodePort in the range answers on the same host port" 'Welcome to nginx' retry_curl http://127.0.0.1:12301/
