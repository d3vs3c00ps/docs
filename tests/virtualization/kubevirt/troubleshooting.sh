#!/usr/bin/env bash
# note: virtualization/kubevirt/troubleshooting.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"
# shellcheck source=common.bash
source "$NOTES_ROOT/tests/virtualization/kubevirt/common.bash"

NOTE=virtualization/kubevirt/troubleshooting
block() { note_block "$NOTE" "$@"; }
install_virtctl
VALID='\): valid$'
kv_source staging/src/kubevirt.io/api/core/v1/types.go >types.go
kv_source pkg/virt-controller/services/template.go >template.go
curl -fsSL -o cdi-common.go "$CDI_RAW/pkg/common/common.go"
# in_file DESC REGEX FILE: a check that prints only the command when it fails.
in_file() { check "$1" grep -Eq -- "$2" "$3"; }
status=$(jq -c '.definitions["v1.VirtualMachineInstanceStatus"].properties | keys' kubevirt.json)

section "Where to look"
in_file "launcher pods carry kubevirt.io=virt-launcher" 'labels\[v1.AppLabel\] = "virt-launcher"' template.go
in_file "the AppLabel is kubevirt.io" 'AppLabel string = "kubevirt.io"' types.go
in_file "QEMU's logs are in the compute container" 'computeContainerName = "compute"' template.go
check_output "virt-handler pods carry kubevirt.io=virt-handler, in a DaemonSet" 'virtv1.AppLabel: +VirtHandlerName' \
  kv_source pkg/virt-operator/resource/generate/components/daemonsets.go

section "VMI stuck in"
export -f fake_nodes
check_output "the KVM jq query names each node and its kvm resource (from the note)" \
  '"name":"node-kvm","kvm":"1k"' bash -c "kubectl() { fake_nodes; }; $(block "VMI stuck in" 2) | jq -c ."
check_output "and null for a node without KVM" '"name":"node-nokvm","kvm":null' \
  bash -c "kubectl() { fake_nodes; }; $(block "VMI stuck in" 2) | jq -c ."
check_output "memoryOvercommit is a KubeVirt setting" '"memoryOvercommit"' \
  jq -c '.definitions["v1.DeveloperConfiguration"].properties | keys' kubevirt.json

section "DataVolume never completes"
in_file "CDI pods carry app=containerized-data-importer" 'CDILabelSelector = CDILabelKey \+ "=" \+ CDILabelValue' cdi-common.go
in_file "the label value is containerized-data-importer" 'CDILabelValue = "containerized-data-importer"' cdi-common.go
in_file "importer pods are named importer-..." 'ImporterPodName = "importer"' cdi-common.go
check_output "and a populator's PVC is prime-...: importer-prime-<uid>" 'primePvcPrefix = "prime"' \
  curl -fsSL "$CDI_RAW/pkg/controller/populators/util.go"
curl -fsSL -o phases.go "$CDI_RAW/staging/src/kubevirt.io/containerized-data-importer-api/pkg/apis/core/v1beta1/types.go"
while read -r p; do
  in_file "$p is a DataVolume phase" "DataVolumePhase = \"$p\"" phases.go
done < <(sed -n '/^## DataVolume never completes/,/^## /p' "$NOTES_ROOT/content/$NOTE.md" | sed -n 's/^| `\([A-Za-z]*\)` |.*/\1/p')
in_file "filesystemOverhead defaults to 6% in CDI $CDI_VERSION (the fix)" 'DefaultGlobalOverhead = "0.06"' cdi-common.go
check_output "it was 5.5% in CDI v1.62" 'DefaultGlobalOverhead = "0.055"' \
  curl -fsSL https://raw.githubusercontent.com/kubevirt/containerized-data-importer/v1.62.0/pkg/common/common.go
check_output "and 6% from CDI v1.64" 'DefaultGlobalOverhead = "0.06"' \
  curl -fsSL https://raw.githubusercontent.com/kubevirt/containerized-data-importer/v1.64.0/pkg/common/common.go

section "VMI Running but unreachable"
assert_match "the VMI status has interfaces" '"interfaces"' "$status"
check_output "masquerade gives the guest 10.0.2.0/24" 'DefaultVMCIDR += "10\.0\.2\.0/24"' \
  kv_source pkg/virt-launcher/virtwrap/api/defaults.go
check_output "the template labels match the schema (from the note)" "$VALID" \
  validate <(block "but unreachable" 2) --def v1.VirtualMachineSpec --partial
skip "a Service on VM labels misses the VMI; default-deny blocks VMs" "needs a cluster that runs KubeVirt"

section "Live migration fails or never completes"
assert_match "the VMI status has migrationState" '"migrationState"' "$status"
assert_match "and migrationMethod" '"migrationMethod"' "$status"
in_file "BlockMigration is a migration method" 'BlockMigration VirtualMachineInstanceMigrationMethod = "BlockMigration"' types.go
in_file "the LiveMigratable condition exists" 'VirtualMachineInstanceIsMigratable VirtualMachineInstanceConditionType = "LiveMigratable"' types.go
while read -r r; do
  in_file "$r is a reason KubeVirt gives" "= \"$r\"" types.go
done < <(sed -n 's/^| `Cannot migrate VMI, Reason: \([A-Za-z]*\)`.*/\1/p' "$NOTES_ROOT/content/$NOTE.md")
check_output "a migration with such a reason is refused when created (the correction)" \
  'Cannot migrate VMI, Reason: %s, Message: %s' kv_source pkg/virt-api/webhooks/validating-webhook/admitters/migration-create-admitter.go
check_output "the ReadWriteOnce message the note quotes" 'live migration requires that all PVCs must be shared' \
  kv_source pkg/virt-handler/vm.go
skip "the jsonpath queries on a live VMI" "needs a cluster that runs KubeVirt"
skip "migrations that never converge; CPU model mismatch" "needs a multi-node cluster that runs KubeVirt"

section "virtctl console hangs"
# The note writes <name> for the VM name.
console=$(block 'console` hangs' 1 | sed 's/<name>/web-01/')
while read -r line; do
  check "virtctl accepts: $line" virtctl_parses "$line"
done <<<"$console"
zypper -n -q install --no-recommends systemd >/dev/null
assert_file "the serial-getty@.service template exists, so serial-getty@ttyS0 does" /usr/lib/systemd/system/serial-getty@.service

section "The VM restarts unexpectedly"
check_output "overcommitGuestOverhead is a VM setting" '"overcommitGuestOverhead"' \
  jq -c '.definitions["v1.ResourceRequirements"].properties | keys' kubevirt.json
check_output "KubeVirt adds its overhead to the pod's request, unless overcommitGuestOverhead (the correction)" \
  'if !guestResourceSpec.OvercommitGuestOverhead' kv_source pkg/virt-controller/services/renderresources.go
check_output "the VMI spec has a livenessProbe" '"livenessProbe"' \
  jq -c '.definitions["v1.VirtualMachineInstanceSpec"].properties | keys' kubevirt.json

section "Guest agent not connected"
in_file "AgentConnected is a VMI condition" '= "AgentConnected"' types.go
check "qemu-guest-agent is a package name" zypper -n -q info qemu-guest-agent

section "Nothing works after installing"
curl -fsSL -o kubevirt-operator.yaml "$KV_DL/kubevirt-operator.yaml"
check_output "the operator manifest deploys virt-operator in namespace kubevirt" 'name: virt-operator' \
  grep -A4 '^kind: Deployment' kubevirt-operator.yaml
for c in VirtAPIName VirtControllerName; do
  check_output "the operator deploys $c" "$c" kv_source pkg/virt-operator/resource/generate/components/deployments.go
done

section "Health check"
block "Health check" 1 >health.sh
check "the script is valid bash" bash -n health.sh
# kubectl answers like a cluster with one pod not running, one node without KVM, and
# a DataVolume still importing.
kubectl() {
  case "$*" in
    "get pods -n kubevirt --no-headers") printf 'virt-api-1 1/1 Running 0 1d\nvirt-handler-x 0/1 CrashLoopBackOff 5 1d\n' ;;
    "get nodes -o json") fake_nodes ;;
    "get vm,vmi -A --no-headers") printf 'default web-01 1d Running True\n' ;;
    "get dv -A --no-headers") printf 'default a Succeeded 100.0%% 1d\ndefault b ImportInProgress 40.0%% 1m\n' ;;
    "get vmim -A --no-headers") ;;
    *) echo "unexpected: kubectl $*" >&2; return 1 ;;
  esac
}
export -f kubectl
out=$(bash health.sh 2>&1)
assert_match "it lists the pod that is not running" 'virt-handler-x 0/1 CrashLoopBackOff' "$out"
assert_no_match "and not the running ones" 'virt-api-1' "$out"
assert_match "it shows the KVM resource of each node" 'node-kvm: 1k' "$out"
assert_match "and NONE where it is missing" 'node-nokvm: NONE' "$out"
assert_match "it lists the DataVolume still importing" 'b ImportInProgress' "$out"
assert_match "with no migration, it says none pending" 'none pending' "$out"
assert_no_match "every kubectl call is one the fake knows" 'unexpected' "$out"
