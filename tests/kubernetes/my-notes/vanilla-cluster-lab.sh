#!/usr/bin/env bash
# note: kubernetes/my-notes/vanilla-cluster-lab.md
# env: compose
# timeout: 3000
# Three Leap containers with systemd and sshd stand in for the VMs, on 10.240.1.0/24 as in
# the note. A second address on k8s-01 stands in for keepalived's virtual IP.
# The note's blocks run inside k8s-01 (ssh loops) or on each node ("connect to each server").
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"

NOTE=kubernetes/my-notes/vanilla-cluster-lab
NODES=(k8s-01 k8s-02 k8s-03)
ARCH=$(uname -m); case $ARCH in aarch64 | arm64) ARCH=arm64 ;; *) ARCH=amd64 ;; esac
docker build -q -t notes-test/leap-systemd:latest "$NOTES_ROOT/tests/envs/leap-systemd" >/dev/null

hosts=$(for i in 1 2 3; do echo "      - k8s-0$i.internal.example.com:10.240.1.3$i"; done
  echo "      - k8s-api.internal.example.com:10.240.1.30"; echo "      - k8s-api:10.240.1.30")
{
  echo "services:"
  for i in 1 2 3; do cat <<EOF
  k8s-0$i:
    image: notes-test/leap-systemd:latest
    hostname: k8s-0$i
    domainname: internal.example.com
    privileged: true
    cgroup: private
    tmpfs: [/run, /run/lock]
    environment: [container=docker]
    # overlayfs cannot nest on the container's own overlay root; kube-proxy loads netfilter modules.
    volumes: [/var/lib/containerd, /lib/modules:/lib/modules:ro]
    extra_hosts:
$hosts
    networks:
      lab: {ipv4_address: 10.240.1.3$i}
EOF
  done
  cat <<'EOF'
networks:
  lab:
    ipam:
      config: [{subnet: 10.240.1.0/24, gateway: 10.240.1.1}]
EOF
} >compose.yaml
docker compose up -d --quiet-pull >/dev/null 2>&1

# on NODE SCRIPT: run SCRIPT as root on NODE, with /etc/environment loaded, as an ssh login would.
on() { docker compose exec -T "$1" bash -c 'set -a; . /etc/environment 2>/dev/null; set +a; cd /root; '"$2" 2>&1; }
# put NODE FILE CONTENT: write a file on NODE (through stdin: no quoting).
put() { docker compose exec -T "$1" sh -c "cat >'$2'" <<<"$3"; }
# each SCRIPT: "connect to each server" and run SCRIPT.
each() { local n; for n in "${NODES[@]}"; do on "$n" "$1" || return; done; }
# The note's blocks download amd64 builds; use this machine's architecture.
block() { note_block "$NOTE" "$@" | sed "s/amd64/$ARCH/g"; }

for n in "${NODES[@]}"; do
  retry 90 bash -c "docker compose exec -T $n systemctl is-system-running 2>/dev/null | grep -Eq 'running|degraded'"
  on "$n" "zypper -n -q install --no-recommends openssh-server openssh-clients sudo >/dev/null && systemctl enable -q --now sshd"
done
on k8s-01 "ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519 && printf 'StrictHostKeyChecking no\n' >/root/.ssh/config"
pub=$(on k8s-01 "cat /root/.ssh/id_ed25519.pub")
for n in "${NODES[@]}"; do on "$n" "mkdir -p -m 700 /root/.ssh && echo '$pub' >>/root/.ssh/authorized_keys"; done
on k8s-01 "ip addr add 10.240.1.30/24 dev eth0" # keepalived's job

section "Our environment"
for i in 1 2 3; do
  check_output "k8s-0$i answers on 10.240.1.3$i, over ssh (from the note)" "^k8s-0$i$" on k8s-01 "ssh 10.240.1.3$i hostname -s"
done
check_output "the virtual address is a secondary address on eth0" 'inet 10\.240\.1\.30/24 .*secondary' on k8s-01 "ip -4 addr show eth0"

section "Installing the binaries"
for i in 2 3 4 5 6 7 8; do
  b=$(block "Installing the binaries" "$i")
  name=$(grep -m1 -oE '^[A-Z_]+_VER=' <<<"$b")
  check "install ${name%_VER=}: the release exists (from the note)" on k8s-01 "$b >/dev/null 2>&1 && $(note_block "$NOTE" "Installing the binaries" "$i" | grep -m1 -E '^curl ' | sed -E 's/^curl -f?L /curl -fsIL -o \/dev\/null /; s/ -o \/tmp.*$//')"
done
versions=$(on k8s-01 "containerd --version; ctr --version; kubectl version --client; kube-apiserver --version; etcd --version; etcdctl version; crictl --version; cfssl version")
for v in 'containerd .* v2\.2\.5' 'ctr .* v2\.2\.5' 'Client Version: v1\.36\.2' '^Kubernetes v1\.36\.2' 'etcd Version: 3\.6\.6' 'etcdctl version: 3\.6\.6' 'crictl version v1\.35\.0' 'Version: 1\.6\.5'; do
  check_output "the binaries report the versions the note installs: /$v/" "$v" echo "$versions"
done
for n in k8s-02 k8s-03; do
  # The note installs every binary on every node; download once, copy to the others.
  on k8s-01 "scp -q /usr/local/bin/* $n:/usr/local/bin/ && ssh $n mkdir -p /opt/cni/bin && scp -q /opt/cni/bin/* $n:/opt/cni/bin/"
done

section "Environment variables"
check "the /etc/environment lines, written over ssh (from the note)" on k8s-01 "$(block "Environment variables")"
check_output "k8s-01: its own address, and the virtual address" '^10\.240\.1\.31 10\.240\.1\.30 k8s-01$' \
  on k8s-01 'echo $KUBERNETES_PUBLIC_ADDRESS $KUBERNETES_VIP_ADDRESS $ETCD_NAME'
check_output "k8s-02: its own address, and no virtual address" '^10\.240\.1\.32 k8s-02$' \
  on k8s-02 'echo $KUBERNETES_PUBLIC_ADDRESS $KUBERNETES_VIP_ADDRESS $ETCD_NAME'

section "Generating the certificates"
check "the directory on each node (from the note)" on k8s-01 "$(block "Generating the certificates" 1)"
for h in "The certificate authority" "The client certificate for the admin user" "The kubelet certificates" \
  "The kube-controller-manager certificate" "The kube-proxy certificate" "The kube-scheduler certificate" \
  "The kube-apiserver certificate" "The ServiceAccount key pair"; do
  check "$h (from the note)" on k8s-01 "$(block "$h" 1)"
  [[ $h == "The kubelet certificates" ]] && check "(signed with each node's names)" on k8s-01 "$(block "$h" 2)"
  # The listing block follows; its output lines are the files cfssl must have written.
  n=2; [[ $h == "The kubelet certificates" ]] && n=3
  listing=$(note_block "$NOTE" "$h" "$n")
  cmd=$(head -1 <<<"$listing")
  check_output "$cmd lists what the note shows" "^$(sed '1d; s/^ *//' <<<"$listing" | sort | paste -sd' ' -)$" \
    on k8s-01 "$cmd | sort | paste -sd' ' -"
done
api=$(on k8s-01 "openssl x509 -in /opt/certs/kubernetes.pem -noout -ext subjectAltName")
for san in 'IP Address:10.43.0.1' 'IP Address:10.240.1.30' 'IP Address:127.0.0.1' 'DNS:k8s-api.internal.example.com' 'DNS:kubernetes.default.svc'; do
  check_output "the API server certificate has $san (from the note)" "$san(,|$)" echo "$api"
done
check_output "the kubelet certificate: CN system:node:k8s-02, O system:nodes (Node Authorizer)" 'O ?= ?system:nodes.*CN ?= ?system:node:k8s-02' \
  on k8s-01 "openssl x509 -in /opt/certs/k8s-02.pem -noout -subject"
check_output "the admin certificate is in system:masters (from the note)" 'O ?= ?system:masters' \
  on k8s-01 "openssl x509 -in /opt/certs/admin.pem -noout -subject"
check "distributing the certificates (from the note)" on k8s-01 "$(block "Distributing the certificates to the nodes")"
check_output "(k8s-03 has its own kubelet certificate)" 'k8s-03\.pem' on k8s-03 "ls /opt/certs"

section "Generating the kubeconfigs"
check "the directory on each node (from the note)" on k8s-01 "$(block "Generating the kubeconfigs")"
for h in "The kubelet kubeconfigs" "The kube-proxy kubeconfig" "The kube-controller-manager kubeconfig" \
  "The kube-scheduler kubeconfig" "The kubeconfig for the admin user"; do
  check "$h (from the note)" on k8s-01 "$(block "$h" 1) >/dev/null"
  listing=$(note_block "$NOTE" "$h" 2)
  check_output "$(head -1 <<<"$listing") lists what the note shows" "^$(sed '1d; s/^ *//' <<<"$listing" | paste -sd' ' -)$" \
    on k8s-01 "$(head -1 <<<"$listing") | paste -sd' ' -"
done
check "distributing the kubeconfigs (from the note)" on k8s-01 "$(block "Distributing the kubeconfigs to the nodes")"

section "The encryption key"
check "generating it (from the note)" on k8s-01 "$(block "Generating an encryption key")"
check "distributing it (from the note)" on k8s-01 "$(block "Distributing the encryption key")"

section "Bootstrapping etcd"
check "the directories and certificates (from the note)" on k8s-01 "$(block "Bootstrapping etcd" 1)"
check "the unit, on each server (from the note)" each "$(block "Bootstrapping etcd" 2)"
put k8s-01 /root/start-etcd.sh "$(block "Bootstrapping etcd" 3)"
check "starting etcd on each node (from the note)" on k8s-01 "timeout 300 bash /root/start-etcd.sh"
check_output "etcdctl member list: three started members (from the note)" '(started, k8s-0[123], https://10\.240\.1\.3[123]:2380, https://10\.240\.1\.3[123]:2379, false.*){3}' \
  on k8s-01 "retry() { for i in \$(seq 30); do \"\$@\" && return; sleep 2; done; return 1; }; retry env $(block "Bootstrapping etcd" 4 | head -1) | paste -sd' ' -"

section "Bootstrapping the control plane"
for h in "The kube-apiserver service" "The kube-controller-manager service" "The kube-scheduler service"; do
  check "$h: the files, copied on each node (from the note)" on k8s-01 "$(block "$h" 1)"
done
check "the kube-apiserver unit, on each server (from the note)" each "$(block "The kube-apiserver service" 2)"
check "the kube-controller-manager unit, on each server (from the note)" each "$(block "The kube-controller-manager service" 2)"
check "the kube-scheduler configuration, on each server (from the note)" each "$(block "The kube-scheduler service" 2)"
check "the kube-scheduler unit, on each server (from the note)" each "$(block "The kube-scheduler service" 3)"
check "starting the control plane (from the note)" on k8s-01 "$(block "Starting the control plane" 1)"
for u in kube-apiserver kube-controller-manager kube-scheduler; do
  check "$u stays up on every node" bash -c "sleep 20; for n in ${NODES[*]}; do docker compose exec -T \$n systemctl is-active -q $u || { docker compose exec -T \$n journalctl -u $u --no-pager | tail -5; exit 1; }; done"
done
ADMIN="--kubeconfig /opt/kubeconfig/admin.kubeconfig"
check_output "the original v1beta1 scheduler configuration is refused (the correction)" 'no kind .?"KubeSchedulerConfiguration.?" is registered for version .?"kubescheduler.config.k8s.io/v1beta1' \
  on k8s-01 "sed 's|config.k8s.io/v1\$|config.k8s.io/v1beta1|' /etc/kubernetes/config/kube-scheduler.yaml >/tmp/old.yaml; timeout 20 kube-scheduler --config=/tmp/old.yaml; true"
check_output "the scheduler's startup errors were RBAC, not a missing CRD: it may list csinodes now (the correction)" '^yes$' \
  on k8s-01 "kubectl $ADMIN auth can-i list csinodes.storage.k8s.io --as system:kube-scheduler"
check_output "the original's csi-api CRD is apiextensions.k8s.io/v1beta1, which is gone (the correction)" 'no matches for kind "CustomResourceDefinition" in version "apiextensions.k8s.io/v1beta1"' \
  on k8s-01 "kubectl create -f https://raw.githubusercontent.com/kubernetes/csi-api/master/pkg/crd/manifests/csinodeinfo.yaml $ADMIN; true"
check_output "kubectl cluster-info, through the virtual address (from the note)" 'Kubernetes control plane is running at https://k8s-api.internal.example.com:6443' \
  on k8s-01 "kubectl cluster-info $ADMIN"
check_output "curl /healthz with the CA (from the note)" '^ok$' on k8s-01 "curl -s --cacert /opt/certs/ca.pem https://k8s-api.internal.example.com:6443/healthz"
check_output "curl /version: v1.36.2" '"gitVersion": "v1\.36\.2"' on k8s-01 "curl -s --cacert /opt/certs/ca.pem https://k8s-api.internal.example.com:6443/version"
check_output "the scheduler and the controller manager elect one leader each" '^kube-controller-manager +k8s-0[123]_.*kube-scheduler +k8s-0[123]_' bash -c \
  "$(declare -f on); on k8s-01 \"kubectl $ADMIN -n kube-system get lease kube-controller-manager kube-scheduler --no-headers -o custom-columns=N:.metadata.name,H:.spec.holderIdentity\" | paste -sd' ' -"
check_output "secrets are encrypted at rest in etcd: k8s:enc:aescbc:v1:key1 (from the note)" 'k8s:enc:aescbc:v1:key1' on k8s-01 \
  "kubectl $ADMIN create secret generic enc-test --from-literal=a=b >/dev/null && ETCDCTL_API=3 etcdctl get /registry/secrets/default/enc-test --endpoints=https://127.0.0.1:2379 --cacert=/etc/etcd/ca.pem --cert=/etc/etcd/kubernetes.pem --key=/etc/etcd/kubernetes-key.pem --print-value-only | head -c 40"

section "Kubelet RBAC"
check "the ClusterRole system:kube-apiserver-to-kubelet (from the note)" on k8s-01 "$(block "Kubelet RBAC" 1)"
check "bound to the kubernetes user (from the note)" on k8s-01 "$(block "Kubelet RBAC" 2)"
check_output "the API server's user may now use nodes/proxy" '^yes$' on k8s-01 "kubectl $ADMIN auth can-i get nodes --subresource=proxy --as kubernetes"

section "Bootstrapping the worker nodes"
check_output "a minimal Leap 16 has no iptables: the note now installs it" '^no$' on k8s-01 "command -v iptables >/dev/null && echo yes || echo no"
check "the packages, on each node (from the note)" each "$(block "Prerequisites" 1 | sed 's/zypper install -y/zypper -n -q install/')"
# Never swapoff here: the swap belongs to the Docker VM, shared with every container.
check "swapon --show (from the note)" on k8s-01 "swapon --show"
check "the directories (from the note)" on k8s-01 "$(block "Prerequisites" 3)"
# percidr N SCRIPT: the note's example CIDR is for k8s-01; each node gets its own.
percidr() { local b=$2 new="POD_CIDR=10.42.$1.0/24"; printf '%s\n' "${b//POD_CIDR=10.42.1.0\/24/$new}"; }
for i in 1 2 3; do
  check "the bridge CNI configuration on k8s-0$i, with its own CIDR (from the note)" on "k8s-0$i" "$(percidr "$i" "$(block "#### CNI" 1)")"
  check "the loopback configuration on k8s-0$i (from the note)" on "k8s-0$i" "$(block "#### CNI" 3)"
  check "the containerd configuration on k8s-0$i (from the note)" on "k8s-0$i" "$(block "#### containerd" 1)"
  check "the containerd unit on k8s-0$i (from the note)" on "k8s-0$i" "$(block "#### containerd" 2)"
  check "the kubelet configuration on k8s-0$i (from the note)" on "k8s-0$i" "$(percidr "$i" "$(block "#### kubelet" 3)")"
  check "the kubelet unit on k8s-0$i (from the note)" on "k8s-0$i" "$(block "#### kubelet" 4)"
  check "the kube-proxy configuration on k8s-0$i (from the note)" on "k8s-0$i" "$(block "#### kube-proxy" 1)"
  check "the kube-proxy unit on k8s-0$i (from the note)" on "k8s-0$i" "$(block "#### kube-proxy" 3)"
done
check "the routes to the other nodes' pods (from the note)" on k8s-01 "$(block "#### CNI" 2)"
check "the kubelet certificates and kubeconfigs (from the note)" on k8s-01 "$(block "#### kubelet" 1) && $(block "#### kubelet" 2)"
check "the kube-proxy kubeconfig (from the note)" on k8s-01 "$(block "#### kube-proxy" 2)"
check "containerd 2.2 accepts the version 3 configuration" each "containerd config dump >/dev/null 2>&1 || { containerd config dump 2>&1 | tail -3; exit 1; }"
on k8s-01 "$(block "Starting the worker services")" >/dev/null 2>&1 || true
if on k8s-01 "tail -n +2 /proc/swaps | grep -q ."; then
  check_output "kubelet refuses to start with swap on (from the note)" 'running with swap on is not supported' bash -c \
    "sleep 10; docker compose exec -T k8s-01 journalctl -u kubelet --no-pager | grep -o 'running with swap on is not supported' | tail -1"
else
  skip "kubelet refuses to start with swap on" "this host has no swap"
fi
# The Docker VM's swap cannot be turned off: allow it, for the test only.
each "grep -q failSwapOn /var/lib/kubelet/kubelet-config.yaml || echo 'failSwapOn: false' >>/var/lib/kubelet/kubelet-config.yaml; systemctl restart kubelet"
check_output "kubectl get nodes: three Ready nodes (from the note)" '^3$' on k8s-01 \
  "for i in \$(seq 90); do [ \"\$(kubectl $ADMIN get nodes --no-headers 2>/dev/null | grep -c ' Ready ')\" = 3 ] && break; sleep 2; done; kubectl $ADMIN get nodes --no-headers | grep -c ' Ready '"
check_output "kube-proxy wrote its iptables rules" 'KUBE-SERVICES' on k8s-01 \
  "for i in \$(seq 30); do iptables-save -t nat | grep -m1 KUBE-SERVICES && exit; sleep 2; done; journalctl -u kube-proxy --no-pager | tail -15; exit 1"

section "DNS"
check "the CoreDNS manifest (from the note)" on k8s-01 "$(block "#### DNS" 1)"
check "CoreDNS becomes ready" on k8s-01 "kubectl $ADMIN -n kube-system rollout status deploy/coredns --timeout=600s ||
  { kubectl $ADMIN get events -A --sort-by=.lastTimestamp | tail -15; journalctl -u containerd -u kubelet --no-pager | grep -iE 'error|fail' | tail -10; exit 1; }"
for i in 1 2 3; do
  check_output "a pod on k8s-0$i resolves kubernetes.default through 10.43.0.10 (from the note)" 'Address:? 10\.43\.0\.1$' on k8s-01 \
    "kubectl $ADMIN run dns-$i --image=busybox:1.37 --restart=Never --overrides='{\"spec\":{\"nodeName\":\"k8s-0$i\"}}' -- nslookup kubernetes.default.svc.cluster.local >/dev/null &&
     for t in \$(seq 90); do kubectl $ADMIN get pod dns-$i -o jsonpath='{.status.phase}' | grep -Eq 'Succeeded|Failed' && break; sleep 2; done; kubectl $ADMIN logs dns-$i"
done

section "Remote access"
check "a kubeconfig for the admin user, on the virtual address (from the note)" on k8s-01 "$(block "## Remote access" 1)"
check_output "kubectl config view: server https://10.240.1.30:6443 (from the note)" 'server: https://10\.240\.1\.30:6443' on k8s-01 "kubectl config view"
check_output "kubectl get nodes without --kubeconfig: three Ready nodes (from the note)" '^3$' on k8s-01 "kubectl get nodes --no-headers | grep -c ' Ready '"
check_output "kubectl version: the server is v1.36.2" 'Server Version: v1\.36\.2' on k8s-01 "kubectl version"

section "Using the API server"
check_output "kubectl get pods -A: CoreDNS is there (the note's 'No resources found' was before DNS)" '^kube-system +coredns-' on k8s-01 "kubectl get pods -A --no-headers"
check_output "the kubernetes Service, created by kube-apiserver, on 10.43.0.1 (from the note)" '^kubernetes +ClusterIP +10\.43\.0\.1 +<none> +443/TCP' on k8s-01 "kubectl get services --no-headers"

section "Creating a Deployment"
check "kubectl create deployment web --image=nginx (from the note)" on k8s-01 "$(block "## Creating a Deployment" 1)"
check "it becomes ready" on k8s-01 "kubectl rollout status deploy/web --timeout=300s"
ip=$(on k8s-01 "kubectl get pods -l app=web -o jsonpath='{.items[0].status.podIP}'")
check_output "the pod's IP comes from its node's CNI range, 10.42.N.0/24 (the correction)" '^10\.42\.[123]\.[0-9]+$' echo "$ip"
for i in 1 2 3; do
  check_output "curl the pod from k8s-0$i: Welcome to nginx! (from the note, through the static routes)" 'Welcome to nginx!' on "k8s-0$i" "curl -s -m 10 http://$ip"
done
