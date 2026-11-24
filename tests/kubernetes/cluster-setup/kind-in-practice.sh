#!/usr/bin/env bash
# note: kubernetes/cluster-setup/kind-in-practice.md
# env: kind
# timeout: 1800
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/cluster-setup/kind-in-practice
WORK=$(mktemp -d)
cd "$WORK"
SHARED=$(kubectl config current-context)   # kind-$CLUSTER
use_test_namespace

section "Install"
check "the note's install block downloads and verifies kind" \
  env HOME="$WORK/home" bash -ec "mkdir -p \$HOME; cd \$HOME; $(note_block "$NOTE" Install 1)"
check_output "the installed binary is the pinned version" "^kind ${KIND_VERSION} " "$WORK/home/.local/bin/kind" version
assert_match "the note pins the same kind version as the tests" "KIND_VERSION=${KIND_VERSION}\$" "$(note_block "$NOTE" Install 1)"

section "Pin the Kubernetes version"
assert_match "the note uses the node image pinned in tests/versions.env" "--image ${KIND_NODE_IMAGE//./\\.}" "$(note_block "$NOTE" 'Pin the Kubernetes' 1)"
kind_cluster demo
check "create a pinned cluster with the note's command" bash -ec "$(note_block "$NOTE" 'Pin the Kubernetes' 1)"
# kind create switches the current context; plain kubectl below must stay on the shared cluster.
kubectl config use-context "$SHARED" >/dev/null
check_output "the node runs the pinned version" 'v1\.37\.0' kubectl --context kind-demo get nodes -o wide

section "Create, list, delete"
check_output "kind get clusters lists it" '^demo$' kind get clusters
check_output "the context is kind-<name>" 'is running at' kubectl cluster-info --context kind-demo

section "Several nodes"
assert_eq "the note's config is the one the shared test cluster uses" \
  "$(grep -v '^ *#' "$NOTES_ROOT/tests/k8s/kind.yaml")" "$(note_block "$NOTE" 'Several nodes' 1 | grep -v '^ *#')"
nodes=$(kubectl --context "$SHARED" get nodes --no-headers -o custom-columns=N:.metadata.name,R:.metadata.labels.node-role\\.kubernetes\\.io/control-plane)
assert_match "node names: <cluster>-control-plane" "^$CLUSTER-control-plane " "$nodes"
assert_match "node names: <cluster>-worker" "^$CLUSTER-worker " "$nodes"
assert_match "node names: <cluster>-worker2" "^$CLUSTER-worker2 " "$nodes"
check_output "docker ps with the kind label lists the node containers" "$CLUSTER-worker2" \
  docker ps --filter label=io.x-k8s.kind.cluster="$CLUSTER" --format '{{.Names}}'

section "Look inside a node"
check_output "static pod manifests on the control plane" 'kube-apiserver\.yaml' \
  docker exec "$CLUSTER-control-plane" ls /etc/kubernetes/manifests
check_output "crictl shows the API server container" 'kube-apiserver' \
  docker exec "$CLUSTER-control-plane" crictl ps --name kube-apiserver
check_output "kubelet and containerd are systemd services" '^active$' \
  docker exec "$CLUSTER-worker" systemctl is-active kubelet containerd
check "kind export logs" kind export logs ./kind-logs --name "$CLUSTER"
check "logs have one directory per node" test -d "./kind-logs/$CLUSTER-control-plane"

section "Use images you built locally"
mkdir -p app && printf 'FROM busybox:1.37\nCMD ["sleep", "3600"]\n' >app/Dockerfile
docker build -q -t myapp:dev app >/dev/null
docker tag myapp:dev myapp:latest
check "kind load docker-image" kind load docker-image myapp:dev myapp:latest --name demo
check_output "crictl images shows the loaded image" 'myapp' docker exec demo-control-plane crictl images
check "the note's CI wait for the default ServiceAccount works" \
  bash -ec "$(note_block "$NOTE" 'Use in CI' 1 | sed -n 's/^ *\(kubectl wait .*\)$/\1/p') --context kind-demo"
kubectl --context kind-demo run dev --image=myapp:dev --restart=Never >/dev/null
check "a pod with the :dev tag starts from the loaded image" \
  kubectl --context kind-demo wait --for=condition=Ready pod/dev --timeout=120s
kubectl --context kind-demo run latest --image=myapp:latest --restart=Never >/dev/null
assert_eq "latest tag defaults to imagePullPolicy Always" Always \
  "$(kubectl --context kind-demo get pod latest -o jsonpath='{.spec.containers[0].imagePullPolicy}')"
check "and the pod fails to pull although the image is on the node" retry 90 bash -c \
  "kubectl --context kind-demo get pod latest -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' | grep -Eq 'ErrImagePull|ImagePullBackOff'"

section "A local registry"
docker rm -f kind-registry >/dev/null 2>&1 || true
check "registry setup steps from the note" bash -ec "$(note_block "$NOTE" 'A local registry' 1)"
check "push to localhost:5001" bash -ec "$(note_block "$NOTE" 'A local registry' 2 | sed 's/--context kind-demo/--context kind-demo -n default/')"
check "the deployment pulls from the local registry" \
  kubectl --context kind-demo -n default rollout status deployment/myapp --timeout=120s
docker rm -f kind-registry >/dev/null

section "Reach your applications: port-forward"
check_output "port-forward block from the note" '<title>Welcome to nginx!</title>' \
  bash -ec "$(note_block "$NOTE" 'port-forward' 1); kill \$!"

section "Port mappings"
kind_cluster ports
note_block "$NOTE" 'Port mappings' 1 >kind-ports.yaml
check_output "NodePort through extraPortMappings answers on localhost:8081" '<title>Welcome to nginx!</title>' \
  bash -ec "$(note_block "$NOTE" 'Port mappings' 2)"
kind delete cluster --name ports >/dev/null
kubectl config use-context "$SHARED" >/dev/null

section "LoadBalancer, Ingress and Gateway API with cloud-provider-kind"
# In the runner (host network), the binary cannot resolve <cluster>-control-plane and falls
# back to random published ports, which Docker Desktop does not expose there. Use the image.
if [[ -n ${NOTES_IN_RUNNER:-} ]]; then
  docker rm -f cloud-provider-kind >/dev/null 2>&1 || true
  check "cloud-provider-kind as a container (from the note)" bash -ec "$(note_block "$NOTE" 'LoadBalancer, Ingress' 2)"
  CPK=
else
  cloud-provider-kind >"$WORK/cpk.log" 2>&1 &
  CPK=$!
fi
assert_match "the note's image tag is the pinned version" "cloud-controller-manager:$CLOUD_PROVIDER_KIND_VERSION\$" \
  "$(note_block "$NOTE" 'LoadBalancer, Ingress' 2)"
kubectl create deployment web --image=nginx:1.29 >/dev/null 2>&1 || true
kubectl expose deployment web --port=80 >/dev/null 2>&1 || true
kubectl rollout status deployment/web --timeout=120s >/dev/null
kubectl expose deployment web --name web-lb --type=LoadBalancer --port=80 >/dev/null
check "the LoadBalancer Service gets an external IP" wait_for_lb_ip service web-lb
LB_IP=$(wait_for_lb_ip service web-lb) || true
check_output "curl through the load balancer IP" 'Welcome to nginx' curl -s --retry 10 --retry-all-errors "http://$LB_IP"
note_block "$NOTE" 'LoadBalancer, Ingress' 4 | kubectl apply -f - >/dev/null
check "an Ingress with no class gets an address" wait_for_lb_ip ingress web
INGRESS_IP=$(wait_for_lb_ip ingress web) || true
check_output "curl through the Ingress IP" 'Welcome to nginx' curl -s --retry 10 --retry-all-errors "http://$INGRESS_IP/"
# Delete what cloud-provider-kind serves while it runs: its finalizers would block the namespace.
kubectl delete service web-lb >/dev/null
kubectl delete ingress web >/dev/null
if [[ -n $CPK ]]; then kill "$CPK" 2>/dev/null || true; else docker rm -f cloud-provider-kind >/dev/null; fi
# The web page, not api.github.com: CI runners share IPs and hit the anonymous API limit (403).
check_output "Ingress NGINX repository is archived (as the note says)" 'This repository was archived by the owner' \
  curl -fsSL https://github.com/kubernetes/ingress-nginx

section "NetworkPolicy works out of the box"
kubectl run client --image=busybox:1.37 --restart=Never -- sleep 3600 >/dev/null
kubectl wait --for=condition=Ready pod/client --timeout=120s >/dev/null
check_output "without a policy, the client reaches web" '^[1-9]' kubectl exec client -- sh -c 'wget -qO- -T 3 http://web | grep -c nginx'
note_block "$NOTE" 'NetworkPolicy works' 2 | kubectl apply -f - >/dev/null
check "with deny-all-ingress, the request times out" retry 20 bash -c '! kubectl exec client -- wget -qO- -T 3 http://web'

section "Networking options"
note_block "$NOTE" 'Networking options' 1 >net.yaml
kind_cluster netopts
check "kind accepts the networking config" kind create cluster --name netopts --config net.yaml --image "$KIND_NODE_IMAGE"
check_output "with no CNI, nodes stay NotReady" 'NotReady' kubectl --context kind-netopts get nodes --no-headers
check_fails "kubeProxyMode none: no kube-proxy DaemonSet" kubectl --context kind-netopts -n kube-system get daemonset kube-proxy
kind delete cluster --name netopts >/dev/null
kubectl config use-context "$SHARED" >/dev/null

section "Change control plane flags: kubeadm patches"
kind_cluster patched
note_block "$NOTE" 'kubeadm patches' 1 >kind-patched.yaml
out=$(bash -ec "$(note_block "$NOTE" 'kubeadm patches' 2)" 2>&1) || true
assert_match "the admission plugin flag reached the API server" 'enable-admission-plugins=NodeRestriction,AlwaysPullImages' "$out"
assert_match "the feature gate reached the API server" 'feature-gates=.*DRADeviceTaintRules=true' "$out"
kind delete cluster --name patched >/dev/null
kubectl config use-context "$SHARED" >/dev/null
check_output "an unknown feature gate stops the API server from starting" 'unrecognized feature gate' \
  bash -c "docker run --rm registry.k8s.io/kube-apiserver:v1.37.0 kube-apiserver --feature-gates=NoSuchGate=true 2>&1; true"

section "Storage"
check_output "default StorageClass standard, local-path, WaitForFirstConsumer" \
  '^standard \(default\) +rancher\.io/local-path +Delete +WaitForFirstConsumer' kubectl get storageclass
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Mi}}}
EOF
sleep 5
assert_eq "a PVC stays Pending until a pod uses it" Pending "$(kubectl get pvc data -o jsonpath='{.status.phase}')"

section "Use in CI"
check_output "scripts/test-notes.sh pins the image and waits, as the note says" '--image "\$KIND_NODE_IMAGE"' \
  grep -A1 'kind create cluster' "$NOTES_ROOT/scripts/test-notes.sh"
check_output "and uses --wait 180s" '--wait 180s' grep -A1 -- '--image "\$KIND_NODE_IMAGE"' "$NOTES_ROOT/scripts/test-notes.sh"
