#!/usr/bin/env bash
# note: kubernetes/configuration/secrets.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/configuration/secrets
cd "$(mktemp -d)"
# Blocks in a callout list keep the list's 2-space indent.
block() { note_block "$NOTE" "$1" "${2:-1}" | sed 's/^  //'; }

# A private registry for the test: a registry pull-through cache of registry.k8s.io,
# with a password, on 127.0.0.1 of each worker. containerd talks plain HTTP to
# localhost only, and every node has its own localhost, hence the DaemonSet.
PORT=$((40000 + RANDOM % 10000))
REG=localhost:$PORT
export REGISTRY_PASSWORD=pw-$RANDOM$RANDOM
cleanup() {
  local rc=$? n
  for n in $(kubectl get nodes -o name | sed 's|node/||'); do
    docker exec "$n" crictl rmi "$REG/pause:3.10" "$REG/pause:3.9" "$REG/pause:3.8" >/dev/null 2>&1 || true
  done
  (exit "$rc")
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
kubectl apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: DaemonSet
metadata: {name: registry}
spec:
  selector: {matchLabels: {app: registry}}
  template:
    metadata: {labels: {app: registry}}
    spec:
      hostNetwork: true
      initContainers:
      - name: htpasswd
        image: mirror.gcr.io/library/httpd:2.4-alpine
        command: [sh, -c, 'htpasswd -Bbn reader "$REGISTRY_PASSWORD" >/auth/htpasswd']
        env: [{name: REGISTRY_PASSWORD, value: "$REGISTRY_PASSWORD"}]
        volumeMounts: [{name: auth, mountPath: /auth}]
      containers:
      - name: registry
        image: mirror.gcr.io/library/registry:3
        env:
        - {name: REGISTRY_HTTP_ADDR, value: "127.0.0.1:$PORT"}
        - {name: REGISTRY_AUTH, value: htpasswd}
        - {name: REGISTRY_AUTH_HTPASSWD_REALM, value: test}
        - {name: REGISTRY_AUTH_HTPASSWD_PATH, value: /auth/htpasswd}
        - {name: REGISTRY_PROXY_REMOTEURL, value: "https://registry.k8s.io"}
        volumeMounts: [{name: auth, mountPath: /auth}]
      volumes: [{name: auth, emptyDir: {}}]
YAML
kubectl rollout status daemonset registry --timeout=180s >/dev/null
worker=$(kubectl get pods -l app=registry -o jsonpath='{.items[0].spec.nodeName}')
check "the test registry asks for a password (401)" retry 30 bash -c \
  "[ \"\$(docker exec $worker curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/v2/)\" = 401 ]"
# The note's placeholders, mapped to the test registry.
adapt() { sed -e "s|registry.example.com/team/private|$REG/pause:3.10|; s|registry.example.com|$REG|"; }
pod_state() { kubectl get pods -l "app=$1" -o jsonpath='{.items[*].status.containerStatuses[*].state.waiting.reason}'; }
export -f pod_state

section "Similarities between ConfigMap and Secrets"
check "kubectl create configmap from the CLI" kubectl create configmap demo --from-literal=a=1
check "kubectl create secret from the CLI" kubectl create secret generic demo --from-literal=a=1 --from-literal=b=2
check "a Secret can hold zero keys" kubectl create secret generic empty
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: both}
spec:
  restartPolicy: Never
  volumes:
  - {name: cm, configMap: {name: demo}}
  - {name: sec, secret: {secretName: demo}}
  containers:
  - name: c
    image: mirror.gcr.io/library/busybox:1.37
    command: [sh, -c, 'echo env $CM $SEC; echo files $(cat /cm/a) $(cat /sec/b)']
    env:
    - {name: CM, valueFrom: {configMapKeyRef: {name: demo, key: a}}}
    - {name: SEC, valueFrom: {secretKeyRef: {name: demo, key: a}}}
    volumeMounts:
    - {name: cm, mountPath: /cm}
    - {name: sec, mountPath: /sec}
YAML
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/both --timeout=120s >/dev/null
check_output "both can be environment variables" '^env 1 1$' kubectl logs both
check_output "both can be files in a volume" '^files 1 2$' kubectl logs both

section "ConfigMap and Secrets are different resources"
kubectl create serviceaccount viewer >/dev/null
kubectl create rolebinding viewer --clusterrole=view --serviceaccount="$TEST_NS:viewer" >/dev/null
as=(--as="system:serviceaccount:$TEST_NS:viewer")
check_output "the view role can read ConfigMaps" '^yes$' kubectl auth can-i get configmaps "${as[@]}"
check_output "but not Secrets" '^no$' bash -c "kubectl auth can-i get secrets ${as[*]}; true"

section "Secrets have an optional type"
typed() { kubectl create secret generic "$1" --type="$2" "${@:3}"; }
check_fails "kubernetes.io/tls without tls.key is rejected" typed t1 kubernetes.io/tls --from-literal=tls.crt=x
check "kubernetes.io/tls with tls.crt and tls.key" typed t2 kubernetes.io/tls --from-literal=tls.crt=x --from-literal=tls.key=y
check_fails "kubernetes.io/basic-auth with neither key is rejected" typed b1 kubernetes.io/basic-auth --from-literal=user=x
check "kubernetes.io/basic-auth with only password" typed b2 kubernetes.io/basic-auth --from-literal=password=x
check_fails "kubernetes.io/ssh-auth without ssh-privatekey is rejected" typed s1 kubernetes.io/ssh-auth --from-literal=key=x
check "kubernetes.io/ssh-auth with ssh-privatekey" typed s2 kubernetes.io/ssh-auth --from-literal=ssh-privatekey=x
check_fails "kubernetes.io/dockerconfigjson without .dockerconfigjson is rejected" typed d1 kubernetes.io/dockerconfigjson --from-literal=x=y
check_fails "kubernetes.io/service-account-token without the annotation is rejected" typed sa1 kubernetes.io/service-account-token
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: viewer-token
  annotations: {kubernetes.io/service-account.name: viewer}
type: kubernetes.io/service-account-token
YAML
check "with the annotation, Kubernetes fills in token, namespace and ca.crt" \
  retry 30 bash -c "[ \"\$(kubectl get secret viewer-token -o go-template='{{len .data}}')\" = 3 ]"
check_output "and they are those three keys" '^ca.crt namespace token$' \
  bash -c "kubectl get secret viewer-token -o json | jq -r '.data | keys | join(\" \")'"
check_output "ServiceAccounts get no token Secret automatically" '^$' kubectl get serviceaccount viewer -o jsonpath='{.secrets}'
check_output "kubectl create token gives a token" '^ey' kubectl create token viewer
check_output "a Secret with no type is Opaque" '^Opaque$' kubectl get secret demo -o jsonpath='{.type}'

section "In practice"
check "kubectl create deployment priv (from the note)" bash -ec "$(block 'In practice' 1 | adapt)"
check "the Pod does not start: ErrImagePull or ImagePullBackOff" \
  retry 90 bash -c "kubectl get pods --selector=app=priv | grep -qE 'ErrImagePull|ImagePullBackOff'"
check_output "kubectl get pods shows it (from the note)" 'ErrImagePull|ImagePullBackOff' bash -ec "$(block 'In practice' 2)"
check_output "the registry refuses the pull: no basic auth credentials" 'pull access denied.*authorization failed: no basic auth credentials' \
  bash -c "kubectl get events --field-selector reason=Failed -o jsonpath='{.items[*].message}'"

section "Creating a secret"
check "kubectl create secret docker-registry regcred (from the note)" bash -ec "$(block 'Creating a secret' 1 | adapt)"
check_output "its type is kubernetes.io/dockerconfigjson" '^kubernetes.io/dockerconfigjson$' \
  kubectl get secret regcred -o jsonpath='{.type}'
check_output "the credentials are tied to the registry address" "\"$REG\"" \
  bash -c "kubectl get secret regcred -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d"
# The same credentials for another registry address are not sent to this one.
kubectl create secret docker-registry other --docker-server=registry.example.com \
  --docker-username=reader --docker-password="$REGISTRY_PASSWORD" >/dev/null
kubectl create deployment wrong --image="$REG/pause:3.8" --dry-run=client -o json |
  jq '.spec.template.spec.imagePullSecrets = [{"name": "other"}]' | kubectl apply -f - >/dev/null
check "credentials for another registry do not help" retry 90 bash -c "pod_state wrong | grep -qE 'ErrImagePull|ImagePullBackOff'"

section "Using the secret"
check "kubectl patch deploy priv with imagePullSecrets (from the note)" bash -ec "$(block 'Using the secret' 1)"

section "Checking the results"
check "the Deployment rolls out" kubectl rollout status deployment priv --timeout=180s
check_output "kubectl get pods shows it Running (from the note)" 'Running' bash -ec "$(block 'Checking the results' 1)"

section "Another way to use the secret"
check "kubectl patch serviceaccount default (from the note)" bash -ec "$(block 'Another way to use the secret' 1)"
kubectl create deployment viasa --image="$REG/pause:3.9" >/dev/null
check "a Pod with no imagePullSecrets of its own starts" kubectl rollout status deployment viasa --timeout=180s
check_output "because the ServiceAccount added regcred to it" '^regcred$' \
  kubectl get pods -l app=viasa -o jsonpath='{.items[0].spec.imagePullSecrets[*].name}'

section "Secrets are displayed with base64 encoding"
check "the data example applies (from the note)" bash -ec "kubectl apply -f - <<'EOF'
$(note_block "$NOTE" 'Secrets are displayed with base64 encoding' 1)
EOF"
check_output "kubectl get secrets -o yaml shows base64" 'onetwothreefour: MTIzNA==' kubectl get secret pin-codes -o yaml
check_output "decoding is easy (from the note)" '^1234$' bash -ec "$(note_block "$NOTE" 'Secrets are displayed with base64 encoding' 2)"
check_output "and 0000 too" '^0000$' bash -c "kubectl get secret pin-codes -o jsonpath='{.data.zerozerozerozero}' | base64 -d"
kubectl delete secret pin-codes >/dev/null

section "Using stringData"
sd=$(note_block "$NOTE" 'Using `stringData`' 1)
check "the stringData example applies (from the note)" bash -ec "kubectl apply -f - <<'EOF'
$sd
EOF"
check_output "it shows up base64-encoded under data" '^MTIzNA== MDAwMA==$' \
  kubectl get secret pin-codes -o jsonpath='{.data.onetwothreefour} {.data.zerozerozerozero}'
check_output "its type is Opaque" '^Opaque$' kubectl get secret pin-codes -o jsonpath='{.type}'
check_fails "unquoted numbers are rejected (the original example)" bash -ec "kubectl apply -f - <<'EOF'
${sd//\"/}
EOF"

section "Encryption at rest"
skip "encryption at rest is configured" "it needs a new API server configuration, and the cluster is shared"

section "Immutable ConfigMaps and Secrets"
kubectl create configmap xyz --from-literal=k=v1 >/dev/null
check "kubectl patch configmap xyz immutable (from the note)" bash -ec "$(note_block "$NOTE" 'Immutable ConfigMaps' 1)"
check_fails "its content cannot change" kubectl patch configmap xyz --patch='{"data": {"k": "v2"}}'
check_fails "immutable cannot go back to false" kubectl patch configmap xyz --patch='{"immutable": false}'
check "delete and create again" bash -c "kubectl delete configmap xyz && kubectl create configmap xyz --from-literal=k=v2"
check "a Secret can be immutable too" kubectl patch secret demo --patch='{"immutable": true}'
check_fails "and then cannot change" kubectl patch secret demo --patch='{"stringData": {"a": "2"}}'
