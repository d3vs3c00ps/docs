#!/usr/bin/env bash
# note: kubernetes/my-notes/concepts.md
# env: kind
# timeout: 400
# A concept page with no commands: the generic claims are checked on kind. The RKE2 and
# Cilium specifics are not tested (no RKE2 here).
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace
export -f retry

section "The nodes"
check_output "the container runtime is containerd (from the note)" '^containerd://' \
  kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.containerRuntimeVersion}'

section "The control plane"
cm=$(kubectl -n kube-system get pod -l component=kube-controller-manager -o jsonpath='{.items[0].spec.containers[0].command}')
check_output "all controllers run in one kube-controller-manager process (from the note)" '"--controllers=\*' echo "$cm"
check_output "the EndpointSlice controller joins Services to Pods (the correction)" '^web-' bash -c \
  "kubectl create deployment web --image=nginx:1.29 >/dev/null && kubectl expose deployment web --port 80 >/dev/null &&
   kubectl rollout status deploy/web --timeout=180s >/dev/null &&
   retry 60 bash -c \"kubectl get endpointslice -l kubernetes.io/service-name=web -o jsonpath='{.items[0].endpoints[0].addresses[0]}' | grep -q .\" &&
   kubectl get endpointslice -l kubernetes.io/service-name=web -o jsonpath='{.items[0].metadata.name}'"
check_output "the Endpoints API is deprecated (the correction)" 'v1 Endpoints is deprecated' bash -c "kubectl get endpoints web 2>&1"

section "Scaling"
kubectl scale deployment web --replicas=3 >/dev/null
kubectl rollout status deploy/web --timeout=180s >/dev/null
check_output "new pods, each with its own IP address (from the note)" '^3$' bash -c \
  "kubectl get pods -l app=web -o jsonpath='{range .items[*]}{.status.podIP}{\"\\n\"}{end}' | sort -u | grep -c ."
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: two-nginx
spec:
  containers:
  - name: first
    image: nginx:1.29
  - name: second
    image: nginx:1.29
EOF
check "two NGINX containers in one pod: the second one fails (from the note)" retry 120 bash -c \
  "kubectl logs two-nginx -c second 2>/dev/null | grep -q 'Address already in use'"
check_output "(the first one serves port 80)" '^true$' bash -c \
  "kubectl get pod two-nginx -o jsonpath='{.status.containerStatuses[?(@.name==\"first\")].ready}'"
