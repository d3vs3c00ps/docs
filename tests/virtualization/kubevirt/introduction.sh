#!/usr/bin/env bash
# note: virtualization/kubevirt/introduction.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"
# shellcheck source=common.bash
source "$NOTES_ROOT/tests/virtualization/kubevirt/common.bash"

NOTE=virtualization/kubevirt/introduction
install_virtctl

section "What KubeVirt is"
crds=$(kv_source pkg/virt-operator/resource/generate/components/crds.go)
assert_match "kubectl get vms: 'vms' is a name of the VirtualMachine CRD" '"vms"' "$crds"
assert_match "kubectl get vmis: 'vmis' is a name of the VirtualMachineInstance CRD" '"vmis"' "$crds"

section "Architecture"
check_output "virt-launcher runs virtqemud, the libvirt daemon for QEMU" '/usr/sbin/virtqemud' \
  kv_source pkg/virt-launcher/virtwrap/util/libvirt_helper.go

section "VirtualMachine and VirtualMachineInstance"
note_block "$NOTE" "VirtualMachine and VirtualMachineInstance" 1 >vm.yaml
check_output "the VirtualMachine matches KubeVirt's API schema (from the note)" '\): valid$' validate vm.yaml
sed '/^      volumes:/,$d' vm.yaml >novolume.yaml
out=$(validate novolume.yaml || true)
assert_match "without its volume, the disk is refused (why the note now has one)" "disk 'rootdisk' has no volume" "$out"
check_output "virtctl start takes a VM name" 'virtctl start \(VM\)' virtctl start --help
check_output "virtctl stop takes a VM name" 'virtctl stop \(VM\)' virtctl stop --help

section "What it needs from the host"
check_output "the node resource is devices.kubevirt.io/kvm at $KUBEVIRT_VERSION" 'devices\.kubevirt\.io/kvm' \
  kv_source pkg/monitoring/rules/recordingrules/nodes.go
# kubectl answers with a node list: one node advertises KVM, the other does not.
export -f fake_nodes
check_output "the jq check shows the KVM resource (from the note)" '"devices\.kubevirt\.io/kvm"' \
  bash -c "kubectl() { fake_nodes; }; $(note_block "$NOTE" "What it needs from the host" 1)"
check_fails "and prints nothing when no node has KVM" \
  bash -c "kubectl() { fake_nodes | jq '.items |= map(select(.metadata.name == \"node-nokvm\"))'; }; $(note_block "$NOTE" "What it needs from the host" 1)"
check_output "useEmulation is off by default" 'DefaultAllowEmulation += false' kv_source pkg/virt-config/virt-config.go
note_block "$NOTE" "What it needs from the host" 2 >emulation.yaml
check_output "the useEmulation setting matches the KubeVirt resource's schema (from the note)" '\): valid$' \
  validate emulation.yaml --def v1.KubeVirt --partial
