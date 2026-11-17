#!/usr/bin/env bash
# note: kubernetes/configuration/sealed-secrets.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace
# retry_out N CMD...: like retry, but prints the output of the first run that exits 0 with
# some output. retry discards output, so check_output cannot use it.
retry_out() {
  local n=$1 i out=
  shift
  for ((i = 1; i <= n; i++)); do
    out=$("$@" 2>&1) && [[ -n $out ]] && { printf '%s\n' "$out"; return 0; }
    sleep 1
  done
  printf '%s\n' "$out"
  return 1
}

NOTE=kubernetes/configuration/sealed-secrets
cd "$(mktemp -d)"
fetch() { curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 "$@"; }
case $(uname -m) in x86_64) arch=amd64 ;; aarch64 | arm64) arch=arm64 ;; esac

# The controller goes into TEST_NS, not kube-system, so the test leaves nothing behind in
# a shared Namespace. Its cluster-scoped objects (CRD, ClusterRole, binding) are removed on exit.
crd_existed=$(kubectl get crd sealedsecrets.bitnami.com -o name 2>/dev/null || true)
cleanup_cluster_scoped() {
  kubectl delete clusterrolebinding sealed-secrets-controller --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete clusterrole secrets-unsealer --ignore-not-found >/dev/null 2>&1 || true
  [[ -n $crd_existed ]] || kubectl delete crd sealedsecrets.bitnami.com --ignore-not-found >/dev/null 2>&1 || true
}
_exit() { local rc=$?; cleanup_cluster_scoped; (exit "$rc"); _k8s_exit; }
trap '_k8s_rc=$?; _exit' EXIT

url=$(note_block "$NOTE" 'Installing the operator' 1 | grep -o 'https://[^ ]*/controller.yaml')
version=$(sed -n 's|.*/download/v\([0-9.]*\)/.*|\1|p' <<<"$url")
mkdir bin
export PATH=$PWD/bin:$PATH
fetch "https://github.com/bitnami/sealed-secrets/releases/download/v$version/kubeseal-$version-linux-$arch.tar.gz" | tar -xz -C bin kubeseal
# kubeseal reads this instead of --controller-namespace, so the note's commands run as written.
export SEALED_SECRETS_CONTROLLER_NAMESPACE=$TEST_NS

section "Installing the operator"
check "the release URL in the note (v$version) downloads" fetch -o controller.yaml "$url"
# Same image through Google's Docker Hub mirror: Docker Hub rate-limits pulls.
sed -i "s/namespace: kube-system/namespace: $TEST_NS/; s|image: docker.io/bitnami/|image: mirror.gcr.io/bitnami/|" controller.yaml
check_output "it installs into kube-system by default" 'namespace: kube-system' fetch "$url"
check "kubectl apply the controller (in the test namespace)" kubectl apply -f controller.yaml
check "the controller starts" kubectl rollout status deploy/sealed-secrets-controller --timeout=240s
check_output "kubeseal $version is the matching client" "kubeseal version: $version" kubeseal --version

section "Installing with Helm"
check_output "the old bitnami-labs Helm repository is gone (404)" '^404$' \
  curl -s -o /dev/null -w '%{http_code}' https://bitnami-labs.github.io/sealed-secrets/index.yaml
helm_cmd=$(note_block "$NOTE" 'Installing with Helm' 1 | sed 's/helm install/helm template/')
retry 3 bash -ec "$helm_cmd >chart.yaml"
retry 3 bash -ec "${helm_cmd/sealed-secrets-controller sealed-secrets/other sealed-secrets} >other.yaml"
check_output "the chart (from the note) names the controller sealed-secrets-controller" \
  '^  name: sealed-secrets-controller$' grep -m1 '^  name: ' chart.yaml
check_output "with another release name, it is <release>-sealed-secrets" '^  name: other-sealed-secrets$' \
  grep -m1 '^  name: ' other.yaml

section "Creating a Secret"
check "kubectl create secret --dry-run=client (from the note)" bash -ec "$(note_block "$NOTE" 'Creating a Secret' 1)"
check_output "it only wrote YAML" '^kind: Secret$' cat secret-aws.yaml
check_fails "nothing was sent to the cluster" kubectl get secret awskey

section "Creating a Sealed Secret"
check "kubeseal (from the note)" bash -ec "$(note_block "$NOTE" 'Creating a Sealed Secret' 1)"
check_output "the output is JSON, a SealedSecret" '^SealedSecret$' jq -r .kind sealed-secret-aws.json
check_output "with the current Namespace of the context" "^$TEST_NS\$" jq -r .metadata.namespace sealed-secret-aws.json
check_output "both keys are encrypted" '^AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY$' \
  jq -r '.spec.encryptedData | keys | join(" ")' sealed-secret-aws.json
check_fails "the clear-text value is not in the file" grep -q 'abc123xyz' sealed-secret-aws.json
check_output "-o yaml gives YAML" '^kind: SealedSecret$' bash -c 'kubeseal -o yaml < secret-aws.yaml'

section "Using a Sealed Secret"
check_fails "the Secret doesn't exist yet (from the note)" bash -c "$(note_block "$NOTE" 'Using a Sealed Secret' 1) | grep -q awskey"
check "kubectl create -f the SealedSecret (from the note)" bash -ec "$(note_block "$NOTE" 'Using a Sealed Secret' 2)"
check "the controller creates the Secret" retry 60 bash -c "$(note_block "$NOTE" 'Using a Sealed Secret' 3) | grep -q awskey"
check_output "with the clear-text value" '^abc123xyz\.\.\.$' \
  bash -c "kubectl get secret awskey -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d"
check_output "an Unsealed event says it was unsealed" 'Unsealed' \
  kubectl get events --field-selector involvedObject.kind=SealedSecret,involvedObject.name=awskey -o jsonpath='{.items[*].reason}'

section "Tweaking secrets"
kubectl delete secret awskey >/dev/null
kubectl delete sealedsecret awskey >/dev/null
jq '.metadata.name = "renamed" | .spec.template.metadata.name = "renamed"' sealed-secret-aws.json >renamed.json
check "kubectl apply the renamed SealedSecret" kubectl apply -f renamed.json
check "it gets Synced=False" retry 60 bash -c \
  "[ \"\$(kubectl get sealedsecret renamed -o jsonpath='{.status.conditions[?(@.type==\"Synced\")].status}')\" = False ]"

section "Sealed Secrets are scoped"
check_output "an ErrUnsealFailed event: no key could decrypt secret" 'ErrUnsealFailed.*no key could decrypt secret' \
  kubectl get events --field-selector involvedObject.name=renamed -o jsonpath='{range .items[*]}{.reason} {.message}{"\n"}{end}'
check_fails "and no Secret" kubectl get secret renamed
skip "moving to another Namespace" "the test stays in its own Namespace; the rename shows the same strict scope"
kubeseal --scope namespace-wide <secret-aws.yaml |
  jq '.metadata.name = "renamed2" | .spec.template.metadata.name = "renamed2"' >renamed2.json
kubectl apply -f renamed2.json >/dev/null
check "with --scope namespace-wide, a renamed SealedSecret unseals" retry 60 kubectl get secret renamed2

section "Working offline"
cp secret-aws.yaml secret.yaml
check "kubeseal --fetch-cert (from the note)" bash -ec "$(note_block "$NOTE" 'Working offline' 1)"
check_output "it is a PEM certificate" '^-----BEGIN CERTIFICATE-----$' cat seal.pem
check "kubeseal --cert (from the note)" bash -ec "$(note_block "$NOTE" 'Working offline' 2)"
check "and with no access to any cluster at all" \
  bash -ec "KUBECONFIG=/dev/null kubeseal --cert seal.pem -n $TEST_NS < secret.yaml > offline.json"
kubectl apply -f offline.json >/dev/null
check "the offline SealedSecret unseals" retry 60 kubectl get secret awskey

section "Key rotation"
keys() { kubectl get secrets -l sealedsecrets.bitnami.com/sealed-secrets-key -o name | sort; }
check_output "the key is a TLS Secret named sealed-secrets-keyXXXXX" '^kubernetes.io/tls$' \
  bash -c "kubectl get \$(kubectl get secrets -l sealedsecrets.bitnami.com/sealed-secrets-key -o name | grep -E 'secret/sealed-secrets-key[a-z0-9]{5}$') -o jsonpath='{.type}'"
check_output "in the controller's Namespace, one key for now" '^1$' bash -c "kubectl get secrets -l sealedsecrets.bitnami.com/sealed-secrets-key --no-headers | wc -l"
check_output "the default renewal period is 30 days (720h)" '720h' \
  bash -c "kubectl exec deploy/sealed-secrets-controller -- controller --help 2>&1 | grep -- --key-renew-period"

section "Rotating the key"
cutoff=$(note_block "$NOTE" 'Rotating the key' 1 | sed "s/-n kube-system/-n $TEST_NS/")
check "add --key-cutoff-time (the note's command)" bash -ec "$cutoff"
check "the controller restarts" kubectl rollout status deploy/sealed-secrets-controller --timeout=240s
check_output "a second key is generated" '^2$' retry_out 60 bash -c '[ "$(kubectl get secrets -l sealedsecrets.bitnami.com/sealed-secrets-key --no-headers | wc -l)" = 2 ] && echo 2'
check_fails "kubeseal --fetch-cert now gives a new certificate" bash -c 'kubeseal --fetch-cert | cmp -s - seal.pem'
kubectl delete sealedsecret awskey >/dev/null
kubectl delete secret awskey --ignore-not-found --wait >/dev/null  # owned by the SealedSecret: may be gone already
kubectl create -f sealed-secret-aws.json >/dev/null
check "the old key is kept: an old SealedSecret still unseals" retry 60 kubectl get secret awskey

section "Discussion (the good)"
count() { grep -c "^kind: $1\$" controller.yaml; }
check_output "one CRD" '^1$' count CustomResourceDefinition
check_output "one Deployment" '^1$' count Deployment
check_output "two Services (controller and metrics)" '^2$' count Service
check_output "a few RBAC objects (ClusterRole, ClusterRoleBinding, 2 Roles, 2 RoleBindings)" '^6$' \
  bash -c "grep -cE '^kind: (Cluster)?Role(Binding)?$' controller.yaml"
