#!/usr/bin/env bash
# note: kubernetes/security/control-plane-auth.md
# env: kind
# timeout: 300
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/security/control-plane-auth
CP=$CLUSTER-control-plane
M=/etc/kubernetes/manifests
on() { docker exec "$CP" "$@"; }
# has FILE FLAG...: every flag the note names is set in that kubeadm manifest.
has() {
  local file=$1 f
  shift
  for f in "$@"; do
    check_output "$(basename "$file" .yaml) runs with $f" "^ *- $f(=|$)" on cat "$file"
  done
}

section "etcd peers and clients"
has $M/etcd.yaml --peer-client-cert-auth=true --peer-cert-file --peer-key-file --peer-trusted-ca-file \
  --client-cert-auth=true --trusted-ca-file --cert-file --key-file
has $M/kube-apiserver.yaml --etcd-cafile --etcd-certfile --etcd-keyfile

section "API server authentication"
has $M/kube-apiserver.yaml --client-ca-file --tls-cert-file --tls-private-key-file \
  --service-account-signing-key-file --service-account-issuer --service-account-key-file
check_output "scheduler and controller manager get a --kubeconfig" '--kubeconfig=/etc/kubernetes/scheduler.conf' \
  on cat $M/kube-scheduler.yaml
check_output "which follows the ~/.kube/config format" 'kind: Config' on cat /etc/kubernetes/scheduler.conf

section "API server clients authorization"
check_output "both authorizers are on (kubeadm writes Node,RBAC)" '--authorization-mode=Node,RBAC' \
  on cat $M/kube-apiserver.yaml
check_output "pods get their ServiceAccount token in the documented file" '^ey' \
  kubectl run sa-token-probe --image=busybox --restart=Never --rm -i --quiet -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/token

section "Kubelet and API server"
check_output "kubelet is started with a --kubeconfig" '--kubeconfig=/etc/kubernetes/kubelet.conf' \
  on bash -c 'tr "\0" " " </proc/$(pgrep -x kubelet)/cmdline'
# kubeadm sets the next two in the kubelet config file rather than as flags.
check_output "kubelet checks client certificates against a CA (clientCAFile)" \
  'clientCAFile: /etc/kubernetes/pki/ca.crt' on cat /var/lib/kubelet/config.yaml
check_output "kubelet delegates authorization to the API server (mode: Webhook)" \
  'mode: Webhook' on cat /var/lib/kubelet/config.yaml
has $M/kube-apiserver.yaml --kubelet-client-certificate --kubelet-client-key

section "Controller manager keys"
has $M/kube-controller-manager.yaml --use-service-account-credentials=true \
  --service-account-private-key-file --cluster-signing-cert-file --cluster-signing-key-file
check_output "the controller manager signs with the key whose public half the API server verifies" \
  '^OK$' on bash -c 'cmp -s <(openssl pkey -in /etc/kubernetes/pki/sa.key -pubout) /etc/kubernetes/pki/sa.pub && echo OK'

section "kube-proxy"
check_output "kube-proxy runs as a DaemonSet with its own Service Account" '^kube-proxy$' \
  kubectl -n kube-system get ds kube-proxy -o jsonpath='{.spec.template.spec.serviceAccountName}'

section "Subject Access Review"
# -v9 only adds HTTP traces; -o json shows the API server's answer.
check_output "the note's SubjectAccessReview: jean.doe may not get pods in kube-system" \
  '"allowed": *false' \
  bash -ec "$(note_block "$NOTE" 'Subject Access Review' 1 | sed 's/kubectl -v9 create -f-/kubectl create -o json -f-/')"
check_output "the same review for a member of system:masters is allowed" '"allowed": *true' \
  bash -ec "$(note_block "$NOTE" 'Subject Access Review' 1 | sed 's/kubectl -v9 create -f-/kubectl create -o json -f-/; s/- foo/- system:masters/')"
