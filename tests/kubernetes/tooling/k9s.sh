#!/usr/bin/env bash
# note: kubernetes/tooling/k9s.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

use_test_namespace
# A fresh HOME: k9s starts with no config, and keeps its state there between runs.
HOME=$(mktemp -d)
export HOME
BIN=$(mktemp -d)
export PATH=$BIN:$PATH
# k9s ARG...: run k9s in a pseudo-terminal, steps on stdin (see tests/lib/tui.py).
k9s_tui() { python3 "$NOTES_ROOT/tests/lib/tui.py" k9s "$@" 2>&1; }

section "Installing k9s"
arch=$(uname -m)
case $arch in aarch64) arch=arm64 ;; x86_64) arch=amd64 ;; esac
check "a binary release installs with one download" bash -ec \
  "curl -fsSL https://github.com/derailed/k9s/releases/download/$K9S_VERSION/k9s_Linux_$arch.tar.gz | tar -xz -C $BIN k9s"
check_output "k9s runs" "Version: +$K9S_VERSION" bash -c 'k9s version | sed "s/\x1b\[[0-9;]*m//g"'
check_output "no setup: it uses the kubectl config, and starts on its current context" \
  "saw /kind-$CLUSTER/" k9s_tui <<<"expect kind-$CLUSTER
send \x03
exit"

section "What kind do we want to see?"
check_output "the pod view lists the keys the note gives" 'exited' k9s_tui <<'EOF'
expect <l> +Logs
expect <d> +Describe
expect <s> +Shell
expect <e> +Edit
expect <shift-f> +Port-Forward
expect <ctrl-k> +Kill
expect <0> +all
send \x03
exit
EOF
check_output "':ns', '/sys', ENTER twice: the pods of kube-system" 'exited' k9s_tui <<'EOF'
expect K9s Rev
send :ns\r
expect kube-system
send /sys
wait 1
send \r
wait 1
send \r
expect pods\( *kube-system
expect coredns
send d
expect Controlled By *: *ReplicaSet/coredns
send \x1b
wait 1
send 0
expect pods\( *all
send \x03
exit
EOF
check_output "'/kub' matches three namespaces, so it is not a way to reach kube-system (the correction)" '^3$' \
  bash -c 'kubectl get namespaces -o name | grep -c kub'

section "Interacting with Deployments"
kubectl create deployment worker --image=busybox:1.37 -- sh -c 'while true; do echo working; sleep 2; done' >/dev/null
kubectl rollout status deployment/worker --timeout=180s >/dev/null
check_output "':deploy', 's' to scale, 'l' for the logs" 'exited' k9s_tui <<'EOF'
expect K9s Rev
send :deploy\r
expect worker
send s
expect Replicas
send \x7f3
wait 1
send \t
wait 1
send \r
wait 3
send l
expect working
send \x03
exit
EOF
check_output "the scale went through" '^3$' kubectl get deployment worker -o jsonpath='{.spec.replicas}'

section "Exit"
check_output "k9s remembers where we were: it starts again on Deployments" 'exited' k9s_tui <<'EOF'
expect deployments\(
send \x03
exit
EOF
