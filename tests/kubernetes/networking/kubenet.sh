#!/usr/bin/env bash
# note: kubernetes/networking/kubenet.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

use_test_namespace

# One nginx pod per worker, so the checks cross a node boundary.
for n in worker worker2; do
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: web-$n, labels: {app: web-$n}}
spec:
  nodeSelector: {kubernetes.io/hostname: $CLUSTER-$n}
  containers: [{name: web, image: nginx:1.29}]
EOF
done
kubectl wait --for=condition=Ready pod/web-worker pod/web-worker2 --timeout=180s >/dev/null
IP1=$(kubectl get pod web-worker -o jsonpath='{.status.podIP}')
IP2=$(kubectl get pod web-worker2 -o jsonpath='{.status.podIP}')

section "The model's guarantees"
check_output "pods on different nodes reach each other directly" 'Welcome to nginx!' \
  kubectl exec web-worker -- curl -fs -m 5 "http://$IP2"
check "each pod is aware of its own IP address" bash -c \
  "kubectl exec web-worker -- hostname -i | grep -qx '$IP1'"
check_output "nodes reach pods directly" 'Welcome to nginx!' \
  docker exec "$CLUSTER-worker2" curl -fs -m 5 "http://$IP1"
NODE_IP=$(kubectl get node "$CLUSTER-worker2" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
check "pods reach nodes directly" \
  kubectl exec web-worker -- sh -c "curl -s -m 5 http://$NODE_IP:10250 >/dev/null 2>&1; [ \$? -ne 28 ]"
# No NAT: the server sees the client's real pod IP in its access log.
kubectl exec web-worker -- curl -fs -m 5 "http://$IP2/kubenet-nat-probe" >/dev/null 2>&1 || true
check_output "pod-to-pod traffic is not NATed: the server logs the client's pod IP" \
  "^$IP1 .*kubenet-nat-probe" kubectl logs web-worker2

section "Multiple moving parts"
check_output "the pod network is implemented by a CNI plugin on each node" '\.conflist' \
  docker exec "$CLUSTER-worker" ls /etc/cni/net.d/
check_output "the service proxy runs as kube-proxy by default" 'kube-proxy' \
  kubectl get daemonsets -n kube-system kube-proxy
