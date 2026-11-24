#!/usr/bin/env bash
# note: virtualization/kubevirt/advanced.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"
# shellcheck source=common.bash
source "$NOTES_ROOT/tests/virtualization/kubevirt/common.bash"

NOTE=virtualization/kubevirt/advanced
block() { note_block "$NOTE" "$@"; }
install_virtctl
MULTUS_VERSION=v4.3.1
VALID='\): valid$'
types=$(kv_source staging/src/kubevirt.io/api/core/v1/types.go)
gates=$(kv_source pkg/virt-config/featuregate/inactive.go)
config=$(kv_source pkg/virt-config/virt-config.go)

section "Storage"
check_output "the DataVolume template fields match the schema (from the note)" "$VALID" \
  validate <(block Storage 1) --def v1.VirtualMachine --partial

section "Snapshots"
block Snapshots 1 >snapshot.yaml
check_output "VirtualMachineSnapshot v1beta1 matches the schema (from the note)" "$VALID" validate snapshot.yaml
block Snapshots 3 >restore.yaml
check_output "the VirtualMachineRestore matches the schema (from the note)" "$VALID" validate restore.yaml
check_output "it restores that snapshot into that VM" '^db-01-before-upgrade db-01 db-01$' python3 -c '
import yaml
s, r = yaml.safe_load(open("snapshot.yaml")), yaml.safe_load(open("restore.yaml"))
print(r["spec"]["virtualMachineSnapshotName"], s["metadata"]["name"] == r["spec"]["virtualMachineSnapshotName"] and r["spec"]["target"]["name"], s["spec"]["source"]["name"])'
check_output "vmsnapshot is a short name" '"vmsnapshot"' kv_source pkg/virt-operator/resource/generate/components/crds.go
check_output "Snapshot is a Beta gate, so on by default" '"name":"Snapshot","state":"Beta"' \
  bash -c "curl -fsSL '$KV_DL/feature-gates.json' | jq -c '.[]'"
skip "a snapshot freezes the guest filesystems through the agent" "needs a cluster that runs KubeVirt and a CSI driver with snapshots"

section "Hotplug"
while read -r line; do
  check "virtctl accepts: $line" virtctl_parses "$line"
done < <(block Hotplug 1)
check_output "--persist has no effect any more (as the note says)" '--persist .*\[deprecated\] this flag has no effect' virtctl addvolume --help
check_output "HotplugVolumes is deprecated, replaced by DeclarativeHotplugVolumes" \
  'HotplugVolumesGate, State: Deprecated, Message: "HotplugVolumes has been deprecated since v1.9.0 and has been replaced by DeclarativeHotplugVolumes"' \
  echo "$gates"
check_output "DeclarativeHotplugVolumes is Beta, so on by default" '"name":"DeclarativeHotplugVolumes","state":"Beta"' \
  bash -c "curl -fsSL '$KV_DL/feature-gates.json' | jq -c '.[]'"

section "Networking"
check_output "the masquerade interface matches the schema (from the note)" "$VALID" \
  validate <(block Networking 1) --def v1.VirtualMachineInstanceSpec --partial --refs
check_output "a VM with no interface gets bridge, not masquerade (the correction)" 'DefaultNetworkInterface += "bridge"' echo "$config"
for b in masquerade bridge passtBinding sriov; do
  check_output "$b is an interface binding" "$VALID" \
    validate <(printf 'domain:\n  devices:\n    interfaces:\n      - name: default\n        %s: {}\n' "$b") \
    --def v1.VirtualMachineInstanceSpec --partial
done
iface=$(jq -c '.definitions["v1.Interface"].properties' kubevirt.json)
assert_match "the old passt binding was removed in v1.3" '"passt":\{[^}]*Removed in v1\.3' "$iface"
assert_match "and so was slirp" '"slirp":\{[^}]*Removed in v1\.3' "$iface"
check_output "PasstBinding is a Beta gate" '"name":"PasstBinding","state":"Beta"' \
  bash -c "curl -fsSL '$KV_DL/feature-gates.json' | jq -c '.[]'"
assert_match "the annotation that allows migration with bridge on the pod network" \
  '"kubevirt.io/allow-pod-bridge-network-live-migration"' "$types"

section "Additional networks with Multus"
curl -fsSL -o multus.yaml \
  "https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/$MULTUS_VERSION/deployments/multus-daemonset.yml"
block "Additional networks" 1 >nad.yaml
check_output "the NetworkAttachmentDefinition matches the Multus CRD (from the note)" "$VALID" \
  python3 "$NOTES_ROOT/tests/virtualization/kubevirt/schema.py" multus.yaml nad.yaml
check_output "its config is valid JSON for the bridge CNI plugin" '^bridge br-vlan100 \{\}$' python3 -c '
import json, yaml
c = json.loads(yaml.safe_load(open("nad.yaml"))["spec"]["config"])
print(c["type"], c["bridge"], json.dumps(c["ipam"]))'
check_output "the VM side matches the schema, each interface with its network (from the note)" "$VALID" \
  validate <(block "Additional networks" 2) --def v1.VirtualMachineInstanceSpec --partial --refs
check_output "and the multus network names the NAD" '^vlan-100$' python3 -c '
import sys, yaml
print(yaml.safe_load(sys.stdin)["networks"][1]["multus"]["networkName"])' < <(block "Additional networks" 2)

section "Live migration"
check_output "the VirtualMachineInstanceMigration matches the schema (from the note)" "$VALID" \
  validate <(block "Live migration" 1)
while read -r line; do
  [[ $line == virtctl* ]] && check "virtctl accepts: $line" virtctl_parses "$line"
done < <(block "Live migration" 2)
check_output "vmim is a short name" '"vmim"' kv_source pkg/virt-operator/resource/generate/components/crds.go
check_output "the VMI status has migrationState" '"migrationState"' \
  jq -c '.definitions["v1.VirtualMachineInstanceStatus"].properties | keys' kubevirt.json
check_output "LiveMigration is GA: there is no gate to turn on (the correction)" \
  'LiveMigrationGate, State: GA' echo "$gates"
check_output "the migration settings match the KubeVirt resource's schema (from the note)" "$VALID" \
  validate <(block "Live migration" 3) --def v1.KubeVirt --partial
check_fails "a misspelled setting is refused (the check is strict)" \
  validate <(block "Live migration" 3 | sed 's/allowAutoConverge/allowAutoConvergence/') --def v1.KubeVirt --partial
check_output "evictionStrategy in the VM template matches the schema (from the note)" "$VALID" \
  validate <(block "Live migration" 4) --def v1.VirtualMachine --partial
check_output "the cluster-wide eviction strategy defaults to None" 'defaultEvictionStrategy := v1.EvictionStrategyNone' \
  kv_source pkg/virt-config/configuration.go
skip "drain migrates with LiveMigrate and shuts down without it; auto-converge" "needs a multi-node cluster that runs KubeVirt"

section "CPU and memory"
check_output "the CPU and memory settings match the schema (from the note)" "$VALID" \
  validate <(block "CPU and memory" 1) --def v1.VirtualMachineInstanceSpec --partial
skip "dedicatedCpuPlacement needs the static CPU Manager policy" "needs a cluster that runs KubeVirt"

section "GPU passthrough"
check_output "permittedHostDevices matches the KubeVirt resource's schema (from the note)" "$VALID" \
  validate <(block "GPU passthrough" 1) --def v1.KubeVirt --partial
check_output "the gpus device matches the VMI schema (from the note)" "$VALID" \
  validate <(block "GPU passthrough" 2) --def v1.VirtualMachineInstanceSpec --partial
res=$(block "GPU passthrough" 1 | sed -n 's/.*resourceName: "\(.*\)"/\1/p')
dev=$(block "GPU passthrough" 2 | sed -n 's/.*deviceName: //p')
assert_eq "the VM asks for the resource the KubeVirt resource permits" "$res" "$dev"
zypper -n -q install --no-recommends pciutils >/dev/null
ids=$(find /usr/share -name pci.ids | head -1)
check_output "10DE:2204 is the RTX 3090 (the fix)" '2204 +GA102 \[GeForce RTX 3090\]' \
  bash -c "sed -n '/^10de /,/^[0-9a-f]/p' '$ids' | grep -P '^\t2204 '"
check_output "and 10DE:2206 is the RTX 3080" '2206 +GA102 \[GeForce RTX 3080\]' \
  bash -c "sed -n '/^10de /,/^[0-9a-f]/p' '$ids' | grep -P '^\t2206 '"
check_output "the GPU gate is GA" 'GPUGate, State: GA' echo "$gates"

section "Benchmarking"
blog=$(sed -n 's|.*\[virtbench\](\(https://[^)]*\)).*|\1|p' "$NOTES_ROOT/content/$NOTE.md")
page=$(curl -fsSL "$blog" | sed 's/<[^>]*>//g')
for term in clone_duration running_time ping_time 'time-to-ready' 'stun time' 'boot storm' 'HTML dashboard'; do
  check "the virtbench article mentions $term" bash -c 'grep -qi -- "$1" <<<"$2"' _ "$term" "$page"
done
