#!/usr/bin/env bash
# note: kubernetes/my-notes/cni.md
# env: kind
# timeout: 300
# Reads a kind node (containerd, kindnet) and calls its reference plugins by hand, in a
# throwaway network namespace. kind ships no bridge plugin, so the note's .conf runs with ptp.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/my-notes/cni
NODE=$(kubectl get nodes -o name | head -1 | cut -d/ -f2)
NS=notes-cni-$RANDOM
node() { docker exec -i "$NODE" sh -c "$1" 2>&1; }
cleanup() {
  node "ip netns del $NS; rm -rf /var/lib/cni/networks/mynet" >/dev/null 2>&1 || true
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT

section "Who invokes the plugins (the correction)"
check_output "kubelet has no CNI flag any more" '^0$' bash -c "docker exec $NODE kubelet --help 2>&1 | grep -c cni || true"
check_output "the container runtime (containerd) reads /etc/cni/net.d (from the note)" "conf_dir = [\"']/etc/cni/net.d" \
  node "containerd config dump | grep -E '^ *conf_dir'"
check_output "and finds the plugins in /opt/cni/bin (from the note)" "bin_dirs? = \\[?[\"']/opt/cni/bin" \
  node "containerd config dump | grep -E '^ *bin_dirs? ='"

section "How is the plugin chosen?"
check_output "the CNI configuration is a file in /etc/cni/net.d (from the note)" '^10-kindnet.conflist$' node "ls /etc/cni/net.d"
conf=$(node "cat /etc/cni/net.d/10-kindnet.conflist")
check_output "a .conflist has a plugins array (from the note)" '^array$' bash -c "jq -r '.plugins | type' <<<\"\$1\"" _ "$conf"
check_output "and no top-level type (from the note)" '^null$' bash -c "jq -r '.type' <<<\"\$1\"" _ "$conf"
check_output "kindnet chains several plugins, ptp first (from the note)" '^ptp portmap$' bash -c \
  "jq -r '[.plugins[].type] | join(\" \")' <<<\"\$1\"" _ "$conf"

section "Plugin invocation: environment variables, JSON on stdin and stdout"
check_output "CNI_COMMAND=VERSION: the plugin answers with JSON (from the note)" '"supportedVersions":\[.*"1.0.0"' \
  node "CNI_COMMAND=VERSION /opt/cni/bin/host-local </dev/null"
# The note's example, with a unique namespace name.
demo=$(note_block "$NOTE" 2 | sed "s/demo/$NS/g")
add=$(node "$demo")
check_output "ADD: JSON on stdout with the address host-local allocated (from the note)" '"address": "10\.22\.[0-9.]+/16"' echo "$add"
check_output "the interface CNI_IFNAME exists in CNI_NETNS (from the note)" 'inet 10\.22\.[0-9.]+/16' node "ip netns exec $NS ip -4 addr show eth0"
check "DEL with the same configuration tears it down (from the note)" node "$(sed '/^ip netns add/d; s/CNI_COMMAND=ADD/CNI_COMMAND=DEL/' <<<"$demo")"
check_output "(eth0 is gone)" 'does not exist' node "ip netns exec $NS ip link show eth0; true"
check_output "the minimal .conf is valid for a plugin: ptp accepts it, with bridge swapped for ptp" '"address": "10\.22\.' node \
  "echo '$(note_block "$NOTE" 3 | jq -c '.type="ptp" | del(.bridge)')' | CNI_COMMAND=ADD CNI_CONTAINERID=$NS-2 CNI_NETNS=/var/run/netns/$NS CNI_IFNAME=eth1 CNI_PATH=/opt/cni/bin /opt/cni/bin/ptp"
