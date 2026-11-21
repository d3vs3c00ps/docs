#!/usr/bin/env bash
# note: kubernetes/configuration/managing-configuration.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/configuration/managing-configuration
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
cd "$(mktemp -d)"
# The note's commands read ~/container.training/k8s/...: a fake HOME holds those files.
export HOME=$PWD
mkdir -p container.training/k8s

# The cluster is shared: the note's blue, green and red Namespaces get unique names here.
blue=$TEST_NS-blue green=$TEST_NS-green red=$TEST_NS-red
cleanup() {
  local rc=$?
  kubectl delete namespace "$blue" "$green" "$red" --wait=false >/dev/null 2>&1 || true
  (exit "$rc")
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
# Docker Hub limits anonymous pulls per IP, and every test shares this IP.
# mirror.gcr.io serves the same Docker Hub images.
mirror() {
  sed -E -e 's#(image[:=] *)(jpetazzo|curlimages)/#\1mirror.gcr.io/\2/#' \
    -e 's#(image[:=] *)(haproxy|registry)\b#\1mirror.gcr.io/library/\2#'
}
rename_ns() { sed -E "s/\bblue\b/$blue/g; s/\bgreen\b/$green/g; s/\bred\b/$red/g"; }
# Blocks in a callout list keep the list's 2-space indent.
block() { note_block "$NOTE" "$1" "${2:-1}" | sed 's/^  //'; }
BUSYBOX=mirror.gcr.io/library/busybox:1.37
CURL=mirror.gcr.io/curlimages/curl:8.17.0
# run_pod NAME: apply the Pod on stdin, wait for it to end, print its logs.
run_pod() {
  kubectl apply -f - >/dev/null
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$1" --timeout=120s >/dev/null
  kubectl logs "$1"
}
indent() { sed "s/^/$(printf '%*s' "$1" '')/"; }

section "Command-line arguments"
check "the consul args example is a valid container spec (from the note)" bash -ec "kubectl apply --dry-run=server -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: consul}
spec:
  containers:
  - name: consul
    image: consul
$(note_block "$NOTE" 'Command-line arguments' 1 | indent 4)
EOF"
out=$(run_pod expand <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: expand}
spec:
  restartPolicy: Never
  containers:
  - name: c
    image: mirror.gcr.io/library/busybox:1.37
    command: [echo]
    args: ["ns=$(NAMESPACE)", "raw=$NAMESPACE"]
    env:
    - name: NAMESPACE
      valueFrom: {fieldRef: {fieldPath: metadata.namespace}}
YAML
)
assert_match "Kubernetes replaces \$(NAMESPACE) in args" "^ns=$TEST_NS " "$out"
assert_match "but leaves \$NAMESPACE as it is: no shell" ' raw=\$NAMESPACE$' "$out"

section "args or command?"
# curlimages/curl has ENTRYPOINT ["/entrypoint.sh"] and CMD ["curl"].
curlpod() {
  run_pod "$1" <<YAML
apiVersion: v1
kind: Pod
metadata: {name: $1}
spec:
  restartPolicy: Never
  containers: [{name: c, image: $CURL, $2}]
YAML
}
check_output "args keeps the ENTRYPOINT" '^curl 8\.17\.0' curlpod args1 'args: ["--version"]'
check_output "args replaces the CMD" '^replaced$' curlpod args2 'args: ["echo", "replaced"]'
check_output "command replaces the ENTRYPOINT" '^hello$' curlpod cmd1 'command: ["echo", "hello"]'
check_output "command and args are joined" '^a b$' curlpod both 'command: ["echo"], args: ["a", "b"]'

section "Environment variables"
envblock=$(note_block "$NOTE" 'Environment variables' 1)
envpod() {
  run_pod envs <<EOF
apiVersion: v1
kind: Pod
metadata: {name: envs}
spec:
  restartPolicy: Never
  containers:
  - name: c
    image: $BUSYBOX
    command: [sh, -c, 'echo \$ADMIN_PORT \$ADMIN_AUTH \$ADMIN_CRED']
$(indent 4 <<<"$1")
EOF
}
check_output "the env example sets the variables (from the note)" '^8080 Basic admin:0pensesame!$' envpod "$envblock"
kubectl delete pod envs >/dev/null
check_fails "an unquoted number is rejected" envpod "${envblock//\"8080\"/8080}"

section "The downward API"
kubectl create deployment api-backend --image=mirror.gcr.io/jpetazzo/color >/dev/null
kubectl expose deployment api-backend --port=80 >/dev/null
kubectl rollout status deployment api-backend --timeout=180s >/dev/null
kubectl create configmap my-app-config --from-literal=foreground=red >/dev/null
fqdn=$(note_block "$NOTE" "Exposing the pod's namespace" 2 | sed 's/^curl /curl -s /')
out=$(run_pod downward <<EOF
apiVersion: v1
kind: Pod
metadata: {name: downward}
spec:
  restartPolicy: Never
  containers:
  - name: test-container
    image: $CURL
    resources: {limits: {memory: 64Mi}}
    command:
    - sh
    - -c
    - |
      echo "ns=\$MY_POD_NAMESPACE ip=\$MY_POD_IP mem=\$MY_MEM_LIMIT fg=\$foreground"
      until curl -s -o /dev/null api-backend; do sleep 1; done  # kube-proxy may lag the new Service
$(indent 6 <<<"$fqdn")
    envFrom: [{configMapRef: {name: my-app-config}}]
    env:
$(note_block "$NOTE" "Exposing the pod's namespace" 1)
$(note_block "$NOTE" "Exposing the pod's IP address" 1)
$(note_block "$NOTE" "Exposing the container's resource limits" 1)
EOF
)
assert_match "MY_POD_NAMESPACE is the Pod's Namespace (from the note)" "ns=$TEST_NS " "$out"
assert_match "MY_POD_IP is the Pod's IP (from the note)" "ip=$(kubectl get pod downward -o jsonpath='{.status.podIP}') " "$out"
assert_match "MY_MEM_LIMIT is the memory limit in bytes (from the note)" ' mem=67108864 ' "$out"
assert_match "envFrom exposes every key of a ConfigMap" ' fg=red$' "$out"
assert_eq "curl api-backend and the FQDN reach the same Service (from the note)" 2 \
  "$(grep -c 'api-backend-' <<<"$out")"

section "Configmaps storing entire files"
printf 'foreground=red\nbackground=blue\n' >app.conf
echo prod=yes >app-prod.conf
mkdir -p config.d/sub && echo a >config.d/a.conf && echo b >config.d/b.conf && echo c >config.d/sub/c.conf
# keys CMD: the keys of the ConfigMap that CMD would create.
keys() { bash -ec "$1 --dry-run=client -o json" | jq -r '.data | to_entries | map("\(.key)=\(.value | rtrimstr("\n"))") | join(" ")'; }
mapfile -t cmds < <(note_block "$NOTE" 'Configmaps storing entire files' 1 | grep '^kubectl')
check_output "--from-file=app.conf: one key, app.conf (from the note)" '^app.conf=foreground=red' keys "${cmds[0]}"
check_output "--from-file=app.conf=app-prod.conf: key app.conf, other file (from the note)" '^app.conf=prod=yes$' keys "${cmds[1]}"
check_output "--from-file=config.d/: one key per file, no subdirectories (from the note)" '^a.conf=a b.conf=b$' keys "${cmds[2]}"

section "Configmaps storing individual parameters"
mapfile -t cmds < <(note_block "$NOTE" 'Configmaps storing individual parameters' 1 | sed -e ':a' -e '/\\$/N; s/\\\n//; ta' | grep '^kubectl')
check_output "--from-literal: two keys (from the note)" '^background=blue foreground=red$' keys "${cmds[0]}"
check_output "--from-env-file: one key per line (from the note)" '^background=blue foreground=red$' keys "${cmds[1]}"

section "Deploying the app"
curl -fsSL "$UPSTREAM/k8s/rainbow.yaml" | rename_ns | mirror >container.training/k8s/rainbow.yaml
check "kubectl apply rainbow.yaml (from the note)" bash -ec "$(block 'Deploying the app' 1)"
for ns in "$blue" "$green" "$red"; do
  check "the color Deployment runs in $ns" kubectl -n "$ns" rollout status deployment color --timeout=180s
done

section "Testing the app"
# -it needs a terminal: script gives it one. Output is saved, not piped: a reader that
# exits early would kill kubectl before --rm deletes the Pod. Attach can miss output: retry.
check "kubectl run curl color.blue.svc (from the note)" retry 5 bash -ec \
  "kubectl delete pod my-test-pod --ignore-not-found --wait >/dev/null
   script -qec \"\$1\" /dev/null >run.out 2>&1 || true
   grep -q 'This is pod $blue/color-' run.out" _ "$(block 'Testing the app' 1 | rename_ns | mirror)"
check "the -it pod is removed" retry 30 bash -c '[ -z "$(kubectl get pod my-test-pod -o name --ignore-not-found)" ]'

section "Creating the HAProxy configuration"
note_block "$NOTE" 'Creating the HAProxy configuration' 1 | rename_ns >container.training/k8s/haproxy.cfg

section "Creating the ConfigMap"
check_fails "the original --from-file=~/... fails: no tilde expansion" \
  bash -ec 'kubectl create configmap haproxy --from-file=~/container.training/k8s/haproxy.cfg --dry-run=client'
check "kubectl create configmap haproxy --from-file ~/... (from the note)" bash -ec "$(block 'Creating the ConfigMap' 1)"
check_output "kubectl get configmap haproxy -o yaml shows the file (from the note)" '^  haproxy.cfg: \|' \
  bash -ec "$(block 'Creating the ConfigMap' 2)"

section "Using the ConfigMap"
note_block "$NOTE" 'Using the ConfigMap' 1 | mirror >container.training/k8s/haproxy.yaml

section "Creating the Pod"
check "kubectl apply haproxy.yaml (from the note)" bash -ec "$(block 'Creating the Pod' 1)"
check "the HAProxy Pod is Ready" kubectl wait --for=condition=Ready pod/haproxy --timeout=180s
IP=$(bash -ec "$(block 'Creating the Pod' 2)"$'\n''echo "$IP"' | tail -1)
assert_match "the note's command gets the Pod IP" '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "$IP"

section "Testing our load balancer"
out=$(IP=$IP bash -ec "$(note_block "$NOTE" 'Testing our load balancer' 2 | mirror)")
# jpetazzo/color answers with an HTML page that says "This is pod <namespace>/<pod>".
read -ra seq <<<"$(grep -oE "This is pod ($blue|$green)/" <<<"$out" | tr ' ' _ | tr '\n' ' ')"
alt=yes
for ((i = 1; i < ${#seq[@]}; i++)); do [[ ${seq[i]} != "${seq[i - 1]}" ]] || alt=no; done
assert_eq "10 answers (from the note, in a Pod)" 10 "${#seq[@]}"
assert_eq "a perfect round robin: blue and green alternate" yes "$alt"
check_output "the image starts HAProxy with -db, in the foreground" '^haproxy -W -db ' \
  bash -c "kubectl exec haproxy -- cat /proc/1/cmdline | tr '\\0' ' '"
check_output "so daemon does not make it exit: no restart" '^0$' \
  kubectl get pod haproxy -o jsonpath='{.status.containerStatuses[0].restartCount}'
# The note warns that HAProxy does not start when a server name does not resolve.
sed "s/color.$green.svc/color.$TEST_NS-nowhere.svc/" container.training/k8s/haproxy.cfg >haproxy.cfg
kubectl create configmap haproxy-bad --from-file haproxy.cfg >/dev/null
sed 's/name: haproxy$/name: haproxy-bad/' container.training/k8s/haproxy.yaml | kubectl apply -f - >/dev/null
check "HAProxy does not start when a Service is missing" \
  retry 90 bash -c "kubectl logs haproxy-bad 2>/dev/null | grep -q 'could not resolve address'"

section "Creating the registry ConfigMap"
check "kubectl create configmap registry (from the note)" bash -ec "$(block 'Creating the registry ConfigMap' 1)"
check_output "kubectl get configmap registry -o yaml (from the note)" '^  http.addr: 0.0.0.0:80$' \
  bash -ec "$(block 'Creating the registry ConfigMap' 2)"

section "Using the registry ConfigMap"
note_block "$NOTE" 'Using the registry ConfigMap' 1 | mirror >container.training/k8s/registry.yaml
check "the Pod definition is valid" kubectl apply --dry-run=server -f container.training/k8s/registry.yaml

section "Creating the registry Pod"
check "kubectl apply registry.yaml (from the note)" bash -ec "$(block 'Creating the registry Pod' 1)"
check "the registry Pod is Ready" kubectl wait --for=condition=Ready pod/registry --timeout=180s
IP=$(bash -ec "$(block 'Creating the registry Pod' 2)"$'\n''echo "$IP"' | tail -1)
check_output "it got its address from the ConfigMap" '^0.0.0.0:80$' \
  kubectl exec registry -- printenv REGISTRY_HTTP_ADDR
kubectl run catalog --restart=Never --image="$CURL" -- sh -c "$(block 'Creating the registry Pod' 3 | sed "s/\$IP/$IP/; s/^curl /curl -s /")" >/dev/null
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/catalog --timeout=120s >/dev/null
check_output "the registry answers on port 80, with no images (from the note, in a Pod)" '^\{"repositories":\[\]\}' kubectl logs catalog
