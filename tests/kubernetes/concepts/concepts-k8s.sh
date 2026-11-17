#!/usr/bin/env bash
# note: kubernetes/concepts/concepts-k8s.md
# env: kind
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/concepts/concepts-k8s
CP=$CLUSTER-control-plane
cd "$(mktemp -d)"

section "Kubernetes architecture: the nodes"
check_output "CONTAINER-RUNTIME shows containerd on every node (from the note)" '^containerd containerd containerd$' \
  bash -c "$(note_block "$NOTE" 'Kubernetes architecture: the nodes' 1) --no-headers | awk '{ sub(/:.*/, \"\", \$NF); print \$NF }' | tr '\n' ' ' | sed 's/ $//'"
for n in "$CP" "$CLUSTER-worker"; do
  check_output "kubelet runs on $n" '^active$' docker exec "$n" systemctl is-active kubelet
  check_output "kube-proxy runs on $n" "^kube-proxy-" \
    kubectl -n kube-system get pods -l k8s-app=kube-proxy --field-selector "spec.nodeName=$n" -o name --no-headers -o jsonpath='{.items[0].metadata.name}'
done

section "Kubernetes architecture: the control plane"
for c in kube-apiserver kube-scheduler kube-controller-manager etcd; do
  check "$c runs in the control plane" kubectl -n kube-system get pod "$c-$CP"
done

section "Running the control plane on special nodes"
taints=$(bash -ec "$(note_block "$NOTE" 'Running the control plane on special nodes' 1)")
assert_match "the control plane node has the control-plane NoSchedule taint (from the note)" \
  "Name: +$CP.Taints: +node-role.kubernetes.io/control-plane:NoSchedule" "$(tr '\n' '.' <<<"$taints")"
assert_no_match "no node uses the master taint" 'node-role.kubernetes.io/master' "$taints"
check_output "and no node has the master label" '^$' kubectl get nodes -l node-role.kubernetes.io/master -o name
check_output "the control-plane label is set" "^node/$CP\$" kubectl get nodes -l node-role.kubernetes.io/control-plane -o name
kubectl create deployment spread --image=nginx --replicas=4 >/dev/null
check "normal Pods start" kubectl wait --for=condition=Available deployment/spread --timeout=180s
check_output "and none of them on the control plane node" '^$' \
  bash -c "kubectl get pods -l app=spread -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | grep -x $CP; true"

section "Some runtimes available through CRI"
check_output "containerd comes with its own CLI, ctr" '^Client:' docker exec "$CP" ctr version
check_output "kubelet uses containerd through the CRI socket" 'containerd.sock' \
  docker exec "$CP" sh -c "cat /var/lib/kubelet/kubeadm-flags.env /var/lib/kubelet/config.yaml 2>/dev/null | grep -o 'containerd.sock' | head -1"

section "Scaling"
note_block "$NOTE" Scaling 1 >two-nginx.yaml
check "the Pod with two NGINX containers is accepted (from the note)" kubectl apply -f two-nginx.yaml
check "one of the two keeps restarting" retry 120 bash -c \
  "kubectl get pod two-nginx -o jsonpath='{.status.containerStatuses[*].restartCount}' | awk '{ exit !(\$1 + \$2 >= 1) }'"
bad=$(kubectl get pod two-nginx -o jsonpath='{range .status.containerStatuses[?(@.restartCount>0)]}{.name}{end}')
check_output "its log shows Address already in use (as the note says)" \
  'bind\(\) to 0\.0\.0\.0:80 failed \(98: Address already in use\)' \
  bash -c "kubectl logs two-nginx -c ${bad:-second} --previous 2>/dev/null || kubectl logs two-nginx -c ${bad:-second}"
kubectl create deployment more --image=nginx --replicas=2 >/dev/null
kubectl wait --for=condition=Available deployment/more --timeout=180s >/dev/null
check_output "more Pods instead: each has its own IP address" '^2$' \
  bash -c "kubectl get pods -l app=more -o jsonpath='{range .items[*]}{.status.podIP}{\"\n\"}{end}' | sort -u | wc -l | tr -d ' '"

section "Together or separate"
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: together}
spec:
  containers:
    - {name: web, image: nginx}
    - {name: client, image: alpine, command: ["sleep", "3600"]}
YAML
kubectl wait --for=condition=Ready pod/together --timeout=180s >/dev/null
check_output "containers in the same Pod talk over localhost" 'Welcome to nginx' \
  kubectl exec together -c client -- wget -qO- http://localhost
check_output "IP addresses belong to Pods: one IP for both containers" '^1$' \
  bash -c "kubectl get pod together -o jsonpath='{.status.podIPs[*].ip}' | wc -w | tr -d ' '"
