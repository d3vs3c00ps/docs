#!/usr/bin/env bash
# note: kubernetes/cluster-setup/k3s.md
# env: k3d
# timeout: 2700
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/cluster-setup/k3s
WORK=$(mktemp -d)
cd "$WORK"
SERVER=k3d-$CLUSTER-server-0
K3S_TAG=${K3S_IMAGE#*:}
K3S_VERSION=${K3S_TAG/-k3s/+k3s}   # v1.37.0+k3s1
use_test_namespace
# The flag from the note's "Disk pressure" section, for extra clusters whose pods must schedule.
NO_EVICT=$(note_block "$NOTE" 'Disk pressure' 2 | grep -o "\-\-k3s-arg '[^']*'" | cut -d"'" -f2)

# Extra k3d clusters this test creates. Deleted on exit.
k3d_clusters=()
cleanup_k3d() { local c; for c in "${k3d_clusters[@]}"; do k3d cluster delete "$c" >/dev/null 2>&1 || true; done; }
_k3s_exit() {
  local rc=$?
  cleanup_k3d
  docker rm -fv k3s-install >/dev/null 2>&1 || true
  _k8s_cleanup
  _t_finish "$rc"
}
trap _k3s_exit EXIT

section "Versions in the note match the pinned test versions"
assert_match "install commands pin $K3S_VERSION" "INSTALL_K3S_VERSION=${K3S_VERSION//+/\\+} sh" "$(note_block "$NOTE" 'Install a server' 1)"
assert_match "k3d example uses $K3S_IMAGE" "--image ${K3S_IMAGE//./\\.}" "$(note_block "$NOTE" 'k3d: k3s in Docker' 1)"

section "Bundled components"
for d in traefik local-path-provisioner metrics-server coredns; do
  # Traefik comes from a Helm install job, so its Deployment appears some time after the cluster.
  check "deployment/$d runs in kube-system" bash -c \
    "kubectl -n kube-system wait --for=create deployment/$d --timeout=180s && kubectl -n kube-system rollout status deployment/$d --timeout=180s"
done
check_output "StorageClass local-path is the default" '^local-path \(default\)' kubectl get storageclass
check "metrics-server serves kubectl top" retry 180 kubectl top nodes
check_output "flannel and the NetworkPolicy controller run in the k3s process, not as pods" '^0$' \
  bash -c "kubectl get pods -A --no-headers | grep -Ec 'flannel|kube-router' || true"

section "ServiceLB"
kubectl create deployment web --image=nginx:1.29 >/dev/null
kubectl rollout status deployment/web --timeout=120s >/dev/null
kubectl expose deployment web --name lb1 --type=LoadBalancer --port=8088 >/dev/null
check "a LoadBalancer Service gets an external IP" wait_for_lb_ip service lb1
check_output "ServiceLB runs a svclb DaemonSet for it" "svclb-lb1" kubectl -n kube-system get daemonset -o name
node_ips=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' | sort)
# ServiceLB adds a node's IP once the svclb pod on that node runs, so the list fills in over a few seconds.
lb_ips_now() { kubectl get service lb1 -o jsonpath='{range .status.loadBalancer.ingress[*]}{.ip}{"\n"}{end}' | sort; }
retry 60 bash -c "[ \"\$(kubectl get service lb1 -o jsonpath='{.status.loadBalancer.ingress[*].ip}' | wc -w)\" = $(wc -l <<<"$node_ips") ]" || true
lb_ips=$(lb_ips_now)
assert_eq "the external IPs are the node IPs" "$node_ips" "$lb_ips"
kubectl expose deployment web --name lb2 --type=LoadBalancer --port=8088 >/dev/null
sleep 20
assert_eq "a second LoadBalancer on the same port stays pending" "" \
  "$(kubectl get service lb2 -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

section "NetworkPolicy controller"
kubectl expose deployment web --port=80 >/dev/null
kubectl run client --image=busybox:1.37 --restart=Never -- sleep 3600 >/dev/null
kubectl wait --for=condition=Ready pod/client --timeout=120s >/dev/null
check "without a policy, the client reaches web" kubectl exec client -- wget -qO- -T 3 http://web
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: deny-all-ingress}
spec: {podSelector: {}, policyTypes: [Ingress]}
EOF
check "k3s enforces a deny-all policy" retry 30 bash -c '! kubectl exec client -- wget -qO- -T 3 http://web'

section "Deploy manifests by dropping files"
docker exec -i "$SERVER" sh -c "cat > /var/lib/rancher/k3s/server/manifests/notes-test.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata: {name: dropped, namespace: $TEST_NS}
data: {version: "1"}
EOF
check "a manifest dropped in the directory is applied" retry 60 kubectl get configmap dropped
docker exec "$SERVER" sed -i 's/version: "1"/version: "2"/' /var/lib/rancher/k3s/server/manifests/notes-test.yaml
check "and applied again when the file changes" retry 60 bash -c '[ "$(kubectl get configmap dropped -o jsonpath={.data.version})" = 2 ]'
docker exec "$SERVER" rm -f /var/lib/rancher/k3s/server/manifests/notes-test.yaml

section "HelmChart and HelmChartConfig"
note_block "$NOTE" 'Deploy manifests' 1 | kubectl apply -f - >/dev/null
check "the HelmChart installs podinfo with 2 replicas" retry 300 bash -c \
  '[ "$(kubectl -n podinfo get deployment podinfo -o jsonpath={.status.readyReplicas} 2>/dev/null)" = 2 ]'
kubectl -n kube-system delete helmchart podinfo >/dev/null
kubectl delete namespace podinfo --wait=false >/dev/null 2>&1 || true
note_block "$NOTE" 'Deploy manifests' 2 | kubectl apply -f - >/dev/null
check "HelmChartConfig changes the bundled Traefik values" retry 300 bash -c \
  "kubectl -n kube-system get deployment traefik -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q 'accesslog=true'"
kubectl -n kube-system delete helmchartconfig traefik >/dev/null

section "Datastore: SQLite on a single server"
check "the single server keeps its state in SQLite" docker exec "$SERVER" test -f /var/lib/rancher/k3s/server/db/state.db
check_fails "and runs no etcd" docker exec "$SERVER" test -d /var/lib/rancher/k3s/server/db/etcd

section "Certificates"
for f in server-ca.crt client-ca.crt request-header-ca.crt; do
  check "tls/$f exists" docker exec "$SERVER" test -f "/var/lib/rancher/k3s/server/tls/$f"
done
docker cp "$SERVER:/var/lib/rancher/k3s/server/tls/server-ca.crt" ca.crt >/dev/null
docker cp "$SERVER:/var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt" leaf.crt >/dev/null
days() { echo $((($(date -d "$(openssl x509 -in "$1" -noout -enddate | cut -d= -f2)" +%s) - $(date +%s)) / 86400)); }
assert_match "the CA is valid for about 10 years" '^36[45][0-9]$' "$(days ca.crt)"
assert_match "the API server certificate is valid for about 1 year" '^36[0-5]$' "$(days leaf.crt)"
check_output "k3s certificate check lists the certificates" 'serving-kube-apiserver\.crt' \
  docker exec "$SERVER" k3s certificate check --output table

section "etcd snapshots"
k3d_clusters+=(etcd)
k3d cluster create etcd --image "$K3S_IMAGE" --k3s-arg "--cluster-init@server:0" --wait \
  --kubeconfig-update-default=false --kubeconfig-switch-context=false >/dev/null
check "embedded etcd is used with --cluster-init" docker exec k3d-etcd-server-0 test -d /var/lib/rancher/k3s/server/db/etcd
check "k3s etcd-snapshot save (from the note)" \
  docker exec k3d-etcd-server-0 sh -c "$(note_block "$NOTE" 'etcd snapshots' 1 | sed 's/^sudo //' | head -1)"
check_output "k3s etcd-snapshot ls shows it" 'before-upgrade' docker exec k3d-etcd-server-0 k3s etcd-snapshot ls
check_output "snapshots go to server/db/snapshots" 'before-upgrade' docker exec k3d-etcd-server-0 ls /var/lib/rancher/k3s/server/db/snapshots
help=$(docker exec k3d-etcd-server-0 k3s server --help)
assert_match "default schedule is every 12 hours" 'etcd-snapshot-schedule-cron value.*default: "0 \*/12 \* \* \*"' "$help"
assert_match "default retention is 5" 'etcd-snapshot-retention value.*default: 5' "$help"
k3d cluster delete etcd >/dev/null

section "k3d: k3s in Docker"
KUBECONFIG_SAVED=$KUBECONFIG
KUBECONFIG=$WORK/k3d-demo.kubeconfig
touch "$KUBECONFIG"
k3d_clusters+=(demo)
out=$(bash -ec "$(note_block "$NOTE" 'k3d: k3s in Docker' 1 | grep -v 'cluster delete')" 2>&1) || true
assert_match "k3d cluster create with 2 agents gives 3 nodes" 'k3d-demo-agent-1 +Ready' "$out"
mkdir -p app && printf 'FROM busybox:1.37\nCMD ["sleep", "3600"]\n' >app/Dockerfile
docker build -q -t myapp:dev app >/dev/null
check "k3d image import" k3d image import myapp:dev -c demo
check_output "a locally built image is on the nodes" 'myapp' docker exec k3d-demo-server-0 crictl images
section "k3d image import of a pulled image"
docker pull -q busybox:1.37 >/dev/null
check_output "k3d reports success for a pulled multi-platform image" 'Successfully imported' k3d image import busybox:1.37 -c demo
if docker info --format '{{.DriverStatus}}' | grep -q containerd.snapshotter; then
  check_fails "but with the containerd image store it is not on the nodes" \
    bash -c "docker exec k3d-demo-server-0 crictl images | grep -q '^docker.io/library/busybox '"
else
  skip "pulled image missing on the nodes" "Docker does not use the containerd image store here"
fi
arch=$(docker version --format '{{.Server.Arch}}')
save=$(note_block "$NOTE" 'k3d: k3s in Docker' 3 | sed "s|linux/amd64|linux/$arch|")
check "docker save --platform, then import the tarball (from the note)" bash -ec "$save"
check_output "then the pulled image is on the nodes" '^docker\.io/library/busybox +1\.37 ' docker exec k3d-demo-server-0 crictl images
check_output "k3d starts a server load balancer container" '^k3d-demo-serverlb$' docker ps --format '{{.Names}}' --filter name=k3d-demo-serverlb
k3d cluster delete demo >/dev/null
k3d_clusters+=(web)
k3d cluster create web --image "$K3S_IMAGE" -p "8080:80@loadbalancer" --wait --k3s-arg "$NO_EVICT" \
  --kubeconfig-update-default=false --kubeconfig-switch-context=false >/dev/null
check_output "-p 8080:80@loadbalancer reaches Traefik on localhost:8080" '^404$' \
  bash -c "sleep 5; curl -s -o /dev/null -w '%{http_code}' --retry 20 --retry-all-errors http://localhost:8080/"
k3d cluster delete web >/dev/null
k3d_clusters+=(ha)
k3d cluster create ha --image "$K3S_IMAGE" --servers 3 --wait \
  --kubeconfig-update-default=false --kubeconfig-switch-context=false >/dev/null
check "--servers 3 turns on embedded etcd" docker exec k3d-ha-server-0 test -d /var/lib/rancher/k3s/server/db/etcd
check_output "all three servers carry the etcd role" '^3$' bash -c \
  "k3d kubeconfig get ha > ha.kubeconfig && kubectl --kubeconfig ha.kubeconfig get nodes -l node-role.kubernetes.io/etcd=true --no-headers | wc -l"
k3d cluster delete ha >/dev/null
KUBECONFIG=$KUBECONFIG_SAVED

section "Disk pressure on a full laptop disk"
assert_match "the note's flag is a kubelet eviction-hard argument for all nodes" \
  '^--kubelet-arg=eviction-hard=imagefs\.available<1%,nodefs\.available<1%@server:\*;agent:\*$' "$NO_EVICT"
check_output "scripts/test-notes.sh creates the shared cluster with the same flag" "--k3s-arg '${NO_EVICT//\*/\\*}'" \
  grep -A2 'k3d cluster create "\$CLUSTER"' "$NOTES_ROOT/scripts/test-notes.sh"
check_output "the kubelet runs with the lowered thresholds" '"imagefs.available":"1%".*"nodefs.available":"1%"|"nodefs.available":"1%".*"imagefs.available":"1%"' \
  kubectl get --raw "/api/v1/nodes/k3d-$CLUSTER-agent-0/proxy/configz"
check_output "and no node carries the disk-pressure taint" '^0$' bash -c \
  "kubectl get nodes -o jsonpath='{.items[*].spec.taints[*].key}' | grep -c disk-pressure || true"

section "Install a server with the script (privileged systemd container)"
docker build -q -t notes-test/leap-systemd:latest "$NOTES_ROOT/tests/envs/leap-systemd" >/dev/null
start_node() {
  docker rm -fv k3s-install >/dev/null 2>&1 || true
  docker run -d --name k3s-install --privileged --cgroupns=private --tmpfs /run --tmpfs /run/lock \
    -v /var/lib/rancher/k3s -e container=docker notes-test/leap-systemd:latest >/dev/null
  # Poll: right after start, systemctl cannot reach systemd yet and fails at once.
  local state
  for _ in $(seq 90); do
    state=$(docker exec k3s-install systemctl is-system-running 2>/dev/null || true)
    [[ $state == running || $state == degraded ]] && break
    sleep 1
  done
}
in_node() { docker exec -i k3s-install bash -ec "$1"; }
start_node
if ! in_node "$(note_block "$NOTE" 'Install a server' 1 | sed 's/sudo //g')" >install.log 2>&1 ||
  ! in_node 'for i in $(seq 120); do k3s kubectl get nodes 2>/dev/null | grep -q " Ready" && exit 0; sleep 2; done; exit 1'; then
  in_node 'systemctl status k3s --no-pager -n 0; journalctl -u k3s --no-pager | grep -v -E "level=info|^.{15} [^ ]+ k3s\[[0-9]+\]: I[0-9]{4}" | tail -25' >>install.log 2>&1 || true
  sed "s/^/#   /" install.log
  skip "k3s install script" "k3s did not start in a nested container here: $(tail -3 install.log | tr '\n' ' ')"
else
  check "the install script starts k3s and the node is Ready" true
  for p in /usr/local/bin/k3s /etc/systemd/system/k3s.service /etc/rancher/k3s/k3s.yaml \
    /var/lib/rancher/k3s/server/token /usr/local/bin/k3s-uninstall.sh /usr/local/bin/k3s-killall.sh; do
    check "the install creates $p" in_node "test -e $p"
  done
  for t in kubectl crictl ctr; do
    check_output "$t is a symlink to k3s" 'k3s$' in_node "readlink /usr/local/bin/$t"
  done
  # The k3d image lacks the k3s subcommands, so the note's tools block is tested on a script install.
  section "Tools built into the binary"
  retry 180 in_node 'k3s kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=kube-dns --timeout=5s' || true
  tools=$(note_block "$NOTE" 'Tools built into' 1 | sed 's/^sudo //; s/ *#.*//')
  check_output "k3s kubectl get pods -A" 'coredns' in_node "$(sed -n 1p <<<"$tools")"
  check_output "k3s crictl ps" 'coredns' in_node "$(sed -n 2p <<<"$tools")"
  check_output "k3s crictl images" 'mirrored-coredns' in_node "$(sed -n 3p <<<"$tools")"
  check_output "k3s ctr -n k8s.io images ls" 'rancher/mirrored-coredns' in_node "$(sed -n 4p <<<"$tools")"
  check_output "k3s check-config runs" 'System:|Generally Necessary' in_node "$(sed -n 5p <<<"$tools") 2>&1; true"
  section "Install a server with the script (continued)"
  check_output "k3s.yaml is readable by root only" '^600$' in_node 'stat -c %a /etc/rancher/k3s/k3s.yaml'
  check "the kubeconfig copy block works" in_node "$(note_block "$NOTE" 'Install a server' 2 | sed 's/^sudo //')"
  check "k3s-uninstall.sh (from the note)" in_node "$(note_block "$NOTE" 'Uninstall' 1 | head -1 | sed 's/^sudo //; s/ *#.*//')"
  check_fails "uninstall removes the binary" in_node 'test -e /usr/local/bin/k3s'
  check_fails "and /var/lib/rancher/k3s content" in_node 'test -e /var/lib/rancher/k3s/server'

  section "The config file (second install)"
  in_node "mkdir -p /etc/rancher/k3s/config.yaml.d
cat > /etc/rancher/k3s/config.yaml <<'EOF'
$(note_block "$NOTE" 'The config file' 1)
EOF
cat > /etc/rancher/k3s/config.yaml.d/50-labels.yaml <<'EOF'
$(note_block "$NOTE" 'The config file' 2)
EOF"
  in_node "$(note_block "$NOTE" 'Install a server' 1 | head -1)" >/dev/null 2>&1
  in_node 'for i in $(seq 120); do k3s kubectl get nodes 2>/dev/null | grep -q " Ready" && exit 0; sleep 2; done; exit 1'
  labels=$(in_node 'k3s kubectl get nodes --show-labels --no-headers')
  assert_match "label from config.yaml is kept" 'site=lab' "$labels"
  assert_match "label from the node-label+ drop-in is added" 'rack=r12' "$labels"
  check_output "write-kubeconfig-mode applies" '^640$' in_node 'stat -c %a /etc/rancher/k3s/k3s.yaml'
  sleep 20
  check_fails "disable: [traefik] keeps Traefik out" in_node 'k3s kubectl -n kube-system get deployment traefik'
  # Node labels apply only when a node registers, so test "last value wins" on `disable`,
  # which k3s reads at every start.
  in_node "printf 'disable:\n  - metrics-server\n' > /etc/rancher/k3s/config.yaml.d/60-disable.yaml && systemctl restart k3s"
  check "without +, a drop-in list replaces the earlier one: Traefik comes back" \
    retry 120 in_node 'k3s kubectl -n kube-system get helmchart traefik'
fi
docker rm -fv k3s-install >/dev/null
