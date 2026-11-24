#!/usr/bin/env bash
# note: virtualization/kubevirt/basics.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"
# shellcheck source=common.bash
source "$NOTES_ROOT/tests/virtualization/kubevirt/common.bash"

NOTE=virtualization/kubevirt/basics
block() { note_block "$NOTE" "$@"; }
zypper -n -q install --no-recommends sudo >/dev/null

# urls_resolve BLOCK: every "https://..." URL in the block, with its variables set, answers.
urls_resolve() {
  local url bad=0
  while read -r url; do
    curl -fsIL -o /dev/null "$url" || { echo "no answer: $url"; bad=1; }
  done < <(grep -o '"https://[^"]*"' <<<"$1" | tr -d '"' | envsubst)
  return "$bad"
}
zypper -n -q install --no-recommends gettext-runtime >/dev/null

section "Installing"
install=$(block Installing 1)
VERSION=$(bash -ec "$(sed -n 1p <<<"$install"); echo \$VERSION")
export VERSION
assert_match "the note's VERSION line finds the latest KubeVirt release" '^v1\.[0-9]+\.[0-9]+$' "$VERSION"
check "the operator and CR URLs exist for that release" urls_resolve "$install"
curl -fsSL -o kubevirt-cr.yaml "$KV_DL/kubevirt-cr.yaml"
check_output "kubevirt-cr.yaml creates the KubeVirt 'kubevirt' in namespace kubevirt, as the wait expects" \
  '^kubevirt/kubevirt$' python3 -c 'import yaml; d = yaml.safe_load(open("kubevirt-cr.yaml")); print(d["metadata"]["namespace"] + "/" + d["metadata"]["name"])'
check_output "and matches the schema" '\): valid$' validate kubevirt-cr.yaml
skip "kubectl wait for the Available condition, and what landed" "needs a cluster that runs KubeVirt"
cdi=$(block CDI 1)
CDI=$(bash -ec "$(sed -n 1p <<<"$cdi"); echo \$CDI")
export CDI
assert_match "the note's CDI line finds the latest CDI release" '^v1\.[0-9]+\.[0-9]+$' "$CDI"
check "the CDI operator and CR URLs exist for that release" urls_resolve "$cdi"
check "virtctl download for this machine's architecture (from the note)" \
  bash -ec "VERSION=$VERSION; $(block virtctl 1 | grep -v krew)"
check_output "virtctl runs and is that release" "GitVersion:\"$VERSION\"" virtctl version --client
check_output "krew has a 'virt' plugin" 'name: virt$' \
  curl -fsSL https://raw.githubusercontent.com/kubernetes-sigs/krew-index/master/plugins/virt.yaml
# From here on, the pinned release.
install_virtctl

section "A first VM"
block "A first VM" 1 >fedora-01.yaml
check_output "fedora-01 matches KubeVirt's API schema (from the note)" '\): valid$' validate fedora-01.yaml
check "the container disk image exists" curl -fsS -o /dev/null \
  -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json' \
  https://quay.io/v2/containerdisks/fedora/manifests/latest
python3 -c 'import yaml; print(yaml.safe_load(open("fedora-01.yaml"))["spec"]["template"]["spec"]["volumes"][1]["cloudInitNoCloud"]["userData"], end="")' >user-data.yaml
if zypper -n -q install --no-recommends cloud-init >/dev/null 2>&1; then
  check "the cloud-init user data passes cloud-init's schema" cloud-init schema -c user-data.yaml
else
  skip "the cloud-init user data passes cloud-init's schema" "no cloud-init package for this distribution"
fi
check_output "virtctl console takes the VM name" 'virtctl console \(VMI\)' virtctl console --help
skip "a container disk loses its writes when the VMI stops" "needs a cluster that runs KubeVirt"

section "Persistent disks with DataVolumes"
block "Persistent disks" 1 >rocky-01.yaml
check_output "rocky-01 matches KubeVirt's API schema (from the note)" '\): valid$' validate rocky-01.yaml
check "the Rocky cloud image URL exists" curl -fsIL -o /dev/null \
  "$(python3 -c 'import yaml; print(yaml.safe_load(open("rocky-01.yaml"))["spec"]["dataVolumeTemplates"][0]["spec"]["source"]["http"]["url"])')"
sources=$(jq -r '.definitions["v1beta1.DataVolumeSource"].properties | keys | join(" ")' kubevirt.json)
for s in http registry pvc snapshot s3 gcs upload blank imageio vddk; do
  assert_match "'$s' is a DataVolume source" "(^| )$s( |$)" "$sources"
done
truncate -s 1M Rocky-9-GenericCloud.qcow2
check "virtctl image-upload accepts the note's flags (from the note)" virtctl_parses "$(block "Persistent disks" 3)"

section "Power and console"
while read -r line; do
  [[ -n $line ]] || continue
  check "virtctl accepts: $line" virtctl_parses "$line"
done < <(block "Power and console" 1)
check_output "virtctl pause NAME, the old form, fails (the correction)" 'accepts 2 arg' bash -c 'virtctl pause rocky-01 2>&1; true'
check_output "virtctl ssh user@NAME, the old form, fails (the correction)" 'must contain type and name' \
  bash -c 'virtctl ssh fedora@fedora-01 2>&1; true'
doc=$(jq -r '.definitions["v1.VirtualMachineSpec"].properties.runStrategy.description' kubevirt.json)
for s in $(block "Power and console" 2 | sed -n 's/.*# //p' | tr -d '|'); do
  assert_match "runStrategy $s exists" "\"$s\"" "$doc"
done
check_output "running is deprecated" 'Deprecated' \
  jq -r '.definitions["v1.VirtualMachineSpec"].properties.running.description' kubevirt.json
skip "runStrategy and running together are refused" "KubeVirt's admission webhook checks this; needs a cluster that runs KubeVirt"

section "Reaching a VM over the network"
block "Reaching a VM" 1 >service.yaml
check_output "the Service matches the Kubernetes API schema (from the note)" '\): valid$' k8s_validate service.yaml
check_output "its selector is the label on fedora-01's VMI template" '^fedora-01 fedora-01$' python3 -c '
import yaml
svc = yaml.safe_load(open("service.yaml"))
vm = yaml.safe_load(open("fedora-01.yaml"))
print(svc["spec"]["selector"]["kubevirt.io/domain"], vm["spec"]["template"]["metadata"]["labels"]["kubevirt.io/domain"])'

section "Instance types"
crds=$(kv_source pkg/virt-operator/resource/generate/components/crds.go)
assert_match "virtualmachineclusterinstancetypes is a resource" 'virtualmachineclusterinstancetypes' "$crds"
assert_match "virtualmachineclusterpreferences is a resource" 'virtualmachineclusterpreferences' "$crds"
block "Instance types" 2 >types.yaml
check_output "the instancetype and preference fields match the schema (from the note)" '\): valid$' \
  validate types.yaml --def v1.VirtualMachine --partial
B=pkg/virt-operator/resource/generate/components/data/common-instancetypes
check_output "u1.medium ships with KubeVirt $KUBEVIRT_VERSION" '^  name: u1\.medium$' kv_source "$B/common-clusterinstancetypes-bundle.yaml"
check_output "and so does the fedora preference" '^  name: fedora$' kv_source "$B/common-clusterpreferences-bundle.yaml"
