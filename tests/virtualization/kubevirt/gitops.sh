#!/usr/bin/env bash
# note: virtualization/kubevirt/gitops.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"
# shellcheck source=common.bash
source "$NOTES_ROOT/tests/virtualization/kubevirt/common.bash"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=virtualization/kubevirt/gitops
block() { note_block "$NOTE" "$@"; }
ARGOCD_VERSION=v3.6.1
VALID='\): valid$'
curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$ARCH/kubectl"
chmod +x /usr/local/bin/kubectl
curl -fsSL -o argocd-crd.yaml "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/crds/application-crd.yaml"
types=$(kv_source staging/src/kubevirt.io/api/core/v1/types.go)
B=pkg/virt-operator/resource/generate/components/data/common-instancetypes
prefs=$(kv_source "$B/common-clusterpreferences-bundle.yaml")

# put BLOCK: write a block to the path in its first line (`# base/x.yaml`), under vms/.
put() {
  local text path
  text=$(block "A basic layout" "$1")
  path=vms/$(sed -n '1s/^# //p' <<<"$text")
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$text" >"$path"
  echo "$path"
}

section "A basic layout"
tree=$(block "A basic layout" 1)
for n in 2 3 4; do
  f=$(put "$n")
  assert_match "${f#vms/} is in the layout" "${f##*/}" "$tree"
done
check_output "the VM template matches KubeVirt's API schema (from the note)" "$VALID" validate vms/base/vm-template.yaml
check_output "u1.medium ships with KubeVirt $KUBEVIRT_VERSION" '^  name: u1\.medium$' \
  kv_source "$B/common-clusterinstancetypes-bundle.yaml"
assert_match "so does the rhel.9 preference" '^  name: rhel\.9$' "$prefs"
assert_no_match "but there is no rocky.9 preference (the correction)" '^  name: rocky\.9$' "$prefs"
check_output "kubectl kustomize builds the dev overlay (from the note)" 'kind: VirtualMachine' \
  bash -ec "$(block "A basic layout" 5)"
kubectl kustomize vms/overlays/dev >dev.yaml
check_output "the result is still a valid VM" "$VALID" validate dev.yaml
check_output "in namespace app-dev, with the dev patches" '^app-dev Manual u1.small$' python3 -c '
import yaml
vm = yaml.safe_load(open("dev.yaml"))
print(vm["metadata"]["namespace"], vm["spec"]["runStrategy"], vm["spec"]["instancetype"]["name"])'
mkdir -p vms/overlays/prefix
printf 'resources: [../../base]\nnamePrefix: prod-\n' >vms/overlays/prefix/kustomization.yaml
kubectl kustomize vms/overlays/prefix >prefix.yaml
check_output "namePrefix renames the VM but not its DataVolume (the warning)" '^prod-app-vm app-vm-root app-vm-root$' python3 -c '
import yaml
vm = yaml.safe_load(open("prefix.yaml"))
print(vm["metadata"]["name"], vm["spec"]["dataVolumeTemplates"][0]["metadata"]["name"],
      vm["spec"]["template"]["spec"]["volumes"][0]["dataVolume"]["name"])'

section "The drift problem"
check_output "the ignoreDifferences entry matches the Argo CD Application schema (from the note)" "$VALID" \
  python3 "$NOTES_ROOT/tests/virtualization/kubevirt/schema.py" argocd-crd.yaml <(block "The drift problem" 1) \
  --def argoproj.io.v1alpha1.Application --partial
assert_match "KubeVirt sets the kubevirt.io/latest-observed-api-version annotation" '"kubevirt.io/latest-observed-api-version"' "$types"
assert_match "and the RestartRequired condition" 'VirtualMachineRestartRequired VirtualMachineConditionType = "RestartRequired"' "$types"
check_output "Argo CD 3.0 ignores the status field on every resource" 'changed from `crd` to `all` resources' \
  curl -fsSL "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/docs/operator-manual/upgrading/2.14-3.0.md"
check_output "Prune=false is an Argo CD sync option annotation (from the note)" \
  "$(block "The drift problem" 2 | sed -n 's/^ *//; /sync-options/p')" \
  curl -fsSL "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/docs/user-guide/sync-options.md"
skip "self-heal rewrites mutated fields; a template edit sets RestartRequired" "needs a cluster with KubeVirt and Argo CD"

section "Power state in Git"
doc=$(jq -r '.definitions["v1.VirtualMachineSpec"].properties.runStrategy.description' kubevirt.json)
while read -r s; do
  assert_match "runStrategy $s exists" "\"$s\"" "$doc"
done < <(sed -n '/^## Power state in Git/,/^## /p' "$NOTES_ROOT/content/$NOTE.md" | sed -n 's/^| `\([A-Za-z]*\)` |.*/\1/p')
skip "virtctl stop on an Always VM is undone by Argo; Manual is not" "needs a cluster with KubeVirt and Argo CD"

section "Secrets in cloud-init"
check_output "cloudInitNoCloud.secretRef matches the schema (from the note)" "$VALID" \
  validate <(block "Secrets in cloud-init" 1) --def v1.VirtualMachineInstanceSpec --partial
printf '#cloud-config\nusers: [default]\n' >user-data.yaml
check_output "kubectl create secret makes the userdata key (from the note, with --dry-run=client)" '^  userdata: ' \
  bash -ec "$(block "Secrets in cloud-init" 2) --dry-run=client -o yaml"
check_output "KubeVirt reads the userdata key from the Secret" '"userdata", "userData"' kv_source pkg/cloud-init/cloud-init.go
check_output "accessCredentials with the guest agent matches the schema (from the note)" "$VALID" \
  validate <(block "Secrets in cloud-init" 3) --def v1.VirtualMachineInstanceSpec --partial
skip "a Secret update changes the keys in a running guest" "needs a cluster that runs KubeVirt and a guest with the agent"
