#!/usr/bin/env bash
# note: kubernetes/extending/kubebuilder.md
# env: kind
# timeout: 2400
# The first part of the lab (Machine, switchPosition, seenAt), with Go and kubebuilder
# downloaded into the test. The Switch part (Owner and dependents, Watches) is not run.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"
use_test_namespace

NOTE=kubernetes/extending/kubebuilder
HOME=$(mktemp -d)
export HOME
cd "$HOME"
export PATH=$HOME/go/bin:$HOME/bin:$HOME/goroot/bin:$PATH GOFLAGS=-modcacherw
CTRL_PID=
cleanup() {
  [ -n "$CTRL_PID" ] && kill -- "-$CTRL_PID" 2>/dev/null
  kubectl delete crd machines.useless.container.training --ignore-not-found --wait=false >/dev/null 2>&1
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
arch=$(uname -m)
case $arch in aarch64) arch=arm64 ;; x86_64) arch=amd64 ;; esac
dedent() { awk 'NF{m=match($0,/[^ ]/)-1; if(min==""||m<min)min=m} {l[NR]=$0} END{for(i=1;i<=NR;i++)print substr(l[i],min+1)}'; }
run() { bash -ec "$(dedent <<<"$1")" 2>&1; }
# start_controller: make run in the background, as the note does in a second terminal.
start_controller() {
  # make run starts a child binary: kill the whole group. wait returns 143, which set -e would stop on.
  if [ -n "$CTRL_PID" ]; then kill -- "-$CTRL_PID" 2>/dev/null; wait "$CTRL_PID" 2>/dev/null || true; fi
  setsid make run >"$HOME/controller.log" 2>&1 &
  CTRL_PID=$!
  retry 600 grep -q 'Starting workers' "$HOME/controller.log"
}
# replace_block FILE START END NEW: replace the lines from /START/ to the first /END/ with NEW.
replace_block() {
  awk -v s="$2" -v e="$3" -v new="$4" '$0 ~ s && !done {print new; skip=1} skip && $0 ~ e {skip=0; done=1; next} !skip' "$1" >"$1.new" && mv "$1.new" "$1"
}

section "Preparation"
mkdir bin goroot
check "install Go" bash -ec "curl -fsSL https://go.dev/dl/go${GO_VERSION}.linux-$arch.tar.gz | tar -xz -C goroot --strip-components=1"
check "install kubebuilder: a release binary in the \$PATH (from the note)" bash -ec \
  "curl -fsSLo bin/kubebuilder https://github.com/kubernetes-sigs/kubebuilder/releases/download/$KUBEBUILDER_VERSION/kubebuilder_linux_$arch && chmod +x bin/kubebuilder"
check "initialize the workspace (from the note)" run "$(note_block "$NOTE" 2)"
cd useless

section "Create scaffolding"
check "kubebuilder create api, answering y to both questions (from the note)" \
  bash -c "printf 'y\ny\n' | $(note_block "$NOTE" 3) 2>&1"
check "the type is in api/v1alpha1/machine_types.go (from the note)" test -f api/v1alpha1/machine_types.go
check_output "the controller is in internal/controller/ (the correction: not internal/controllers/)" \
  '^internal/controller/machine_controller.go$' bash -c "ls internal/*/machine_controller.go"

section "Edit type, Go markers"
replace_block api/v1alpha1/machine_types.go '^// MachineSpec defines' '^}' "$(note_block "$NOTE" 4)"
check_output "the note's struct tag uses simple backticks" '`json:"switchPosition,omitempty"`$' grep SwitchPosition api/v1alpha1/machine_types.go
# The markers go above "type Machine struct", next to the scaffolded ones.
sed -i "s|^type Machine struct|$(note_block "$NOTE" 7)\ntype Machine struct|" api/v1alpha1/machine_types.go
check_output "the scaffold already has the object:root and subresource:status markers (from the note)" \
  '^// \+kubebuilder:object:root=true .*// \+kubebuilder:subresource:status ' bash -c "grep -E '^// ?\+kubebuilder:(object:root|subresource:status)' api/v1alpha1/machine_types.go | head -2 | tr '\n' ' '"

section "Installing the CRD"
check_output "make install depends on manifests and kustomize, not on the Go build (the correction)" '^install: manifests kustomize' grep '^install:' Makefile
# The Go module proxy sometimes drops a download: try three times.
check "make install: generates the CRD and applies it (from the note)" bash -c "for i in 1 2 3; do make install 2>&1 && exit; sleep 5; done; exit 1"
check_output "the CRD has switchPosition and the Position column" 'switchPosition.*"name":"Position"' bash -c \
  "kubectl get crd machines.useless.container.training -o json | jq -c '.spec.versions[0] | [.schema.openAPIV3Schema.properties.spec.properties, .additionalPrinterColumns]'"

section "Creating a machine"
sample=config/samples/useless_v1alpha1_machine.yaml
check "the sample file exists (from the note)" test -f "$sample"
note_block "$NOTE" 8 | sed 's/^  labels: # \.\.\.$//' >"$sample"
check "apply it to the cluster (from the note)" kubectl apply -f "$sample"
check_output "kubectl get machines shows the Position column" '^machine-1 +up( |$)' kubectl get machines

section "Loading an object, running the controller"
ctl=internal/controller/machine_controller.go
load=$(note_block "$NOTE" 9)
awk -v code="$load" '/TODO\(user\): your logic here/ {print code; next} {print}' "$ctl" >"$ctl.new" && mv "$ctl.new" "$ctl"
# make run regenerates the deepcopy code first; go build needs it too.
make generate >/dev/null 2>&1
check_output "the scaffold imports the log package as logf (the correction)" '^\s*logf "sigs.k8s.io/controller-runtime/pkg/log"$' cat "$ctl"
check "the note's code, with logf.FromContext, builds" go build ./...
start_controller
export -f retry
check_output "the controller reconciles our machine (from the note)" 'reconciling.*"switchPosition": "up"' bash -c "retry 60 grep -q reconciling $HOME/controller.log; grep reconciling $HOME/controller.log"
kubectl delete machine machine-1 >/dev/null
check "deleting the machine gives errors (from the note)" retry 60 grep -q 'error getting object' "$HOME/controller.log"
check_output "(a not found error, returned to controller-runtime)" 'Reconciler error.*not found' cat "$HOME/controller.log"

section "IgnoreNotFound, updating the machine"
perl -0pi -e 's/(logger\.Info\("error getting object"\)\n\s*)return ctrl\.Result\{\}, err/$1'"$(note_block "$NOTE" 11 | sed 's/[\/&]/\\&/g')"'/' "$ctl"
update=$(note_block "$NOTE" 12)
awk -v code="$update" '/"switchPosition", machine.Spec.SwitchPosition,$/ {print; getline; print; print code; next} {print}' "$ctl" >"$ctl.new" && mv "$ctl.new" "$ctl"
check "it builds" go build ./...
start_controller
kubectl apply -f "$sample" >/dev/null
check "the operator moves the switch back to down (from the note)" retry 60 bash -c \
  "[ \"\$(kubectl get machine machine-1 -o jsonpath='{.spec.switchPosition}')\" = down ]"
kubectl patch machine machine-1 --type=merge -p '{"spec":{"switchPosition":"up"}}' >/dev/null
check "each time we change it (from the note)" retry 60 bash -c \
  "[ \"\$(kubectl get machine machine-1 -o jsonpath='{.spec.switchPosition}')\" = down ]"
: >"$HOME/controller.log.mark"
kubectl delete machine machine-1 >/dev/null
sleep 5
check_output "with IgnoreNotFound, deletion gives no Reconciler error (from the note)" '^0$' bash -c \
  "grep -c 'Reconciler error' $HOME/controller.log || true"

section "Improving our controller, take 2: seenAt"
replace_block api/v1alpha1/machine_types.go '^// MachineStatus defines' '^}' "$(note_block "$NOTE" 14)"
sed -i "s|^type Machine struct|$(note_block "$NOTE" 15)\ntype Machine struct|" api/v1alpha1/machine_types.go
setseen=$(note_block "$NOTE" 16)
useseen=$(note_block "$NOTE" 17)
# Replace the first version of the switch code with the seenAt versions.
perl -0pi -e 's/^if machine\.Spec\.SwitchPosition != "down" \{\n.*?\n\}\n//sm' "$ctl"
awk -v a="$setseen" -v b="$useseen" '/^\treturn ctrl.Result\{\}, nil$/ && !done {print a; print b; done=1} {print}' "$ctl" >"$ctl.new" && mv "$ctl.new" "$ctl"
grep -q '"time"' "$ctl" || sed -i 's/^import (/import (\n\t"time"\n/' "$ctl"
grep -q 'metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"' "$ctl" || sed -i 's/^import (/import (\n\tmetav1 "k8s.io\/apimachinery\/pkg\/apis\/meta\/v1"\n/' "$ctl"
make generate >/dev/null 2>&1
check "it builds (with the time and metav1 imports, as the note says)" go build ./...
check "make install again: the CRD gets status.seenAt" bash -c "for i in 1 2 3; do make install 2>&1 && exit; sleep 5; done; exit 1"
start_controller
kubectl apply -f "$sample" >/dev/null
check_output "the controller notes when it saw the machine (from the note)" '^20[0-9]{2}-' bash -c \
  "retry 30 bash -c \"kubectl get machine machine-1 -o jsonpath='{.status.seenAt}' | grep -q .\"; kubectl get machine machine-1 -o jsonpath='{.status.seenAt}'"
check_output "the Seen column (from the note)" '^NAME +POSITION +SEEN' kubectl get machines
check "and goes down after about 5 seconds (from the note)" retry 60 bash -c \
  "[ \"\$(kubectl get machine machine-1 -o jsonpath='{.spec.switchPosition}')\" = down ]"
