#!/usr/bin/env bash
# note: kubernetes/packaging/helm-create-better-chart.md
# env: kind
# timeout: 1500
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/packaging/helm-create-better-chart
use_test_namespace
HOME=$(mktemp -d)
export HOME
cd "$HOME"
# The note's namespace, made unique for this run.
HC=$TEST_NS-hc
cleanup() {
  kubectl delete namespace "$HC" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
run() { bash -ec "$1" 2>&1; }
# in_file FILE SNIPPET: every line of the note's snippet is in FILE (spaces ignored).
in_file() {
  local l
  while read -r l; do
    [[ -z $l ]] && continue
    tr -d ' ' <"$1" | grep -qF -- "${l// /}" || { echo "missing: $l"; return 1; }
  done <<<"$2"
}
# pods_ready: the READY column of each component, e.g. "hasher=1/1 redis=0/1 ...".
pods_ready() {
  kubectl get pods --no-headers | awk '{split($1,a,"-"); printf "%s=%s ", a[1], $2}' | xargs -n1 | sort | xargs
}

section "Creating a generic chart"
check "helm create helmcoins (from the note)" run "$(note_block "$NOTE" 1)"
check_output "it deploys nginx by default" 'repository: nginx' cat helmcoins/values.yaml

section "Writing values.yaml for our components"
model=$(note_block "$NOTE" 3)
assert_match "the model is valid YAML for worker" 'repository: dockercoins/worker' "$model"
for c in hasher rng webui worker; do echo "${model//worker/$c}" >"$c.yaml"; done
redis=${model//dockercoins\/worker/redis}
echo "${redis//v0.1/latest}" >redis.yaml
check_output "redis.yaml: redis:latest" 'tag: latest$' cat redis.yaml

section "Deploying DockerCoins components"
check "create the namespace (from the note)" run "$(note_block "$NOTE" 4 | sed "s/helmcoins/$HC/")"
check "switch to it (the note's fallback for kns)" kubectl config set-context --current --namespace "$HC"
check "install the 5 components (from the note)" run "$(note_block "$NOTE" 8)"
check "the loop is idempotent: running it again works" run "$(note_block "$NOTE" 8)"
check_output "kubectl get all (from the note)" 'deployment.apps/worker-helmcoins' run "$(note_block "$NOTE" 10)"

section "The image tag"
check_output "the images are pulled with their tags (the correction)" \
  'dockercoins/hasher:v0.1 dockercoins/rng:v0.1 dockercoins/webui:v0.1 dockercoins/worker:v0.1 redis:latest' \
  bash -c "kubectl get deploy -o jsonpath='{.items[*].spec.template.spec.containers[0].image}' | xargs -n1 | sort | xargs"
check_output "tree helmcoins (from the note)" 'deployment.yaml' run "$(note_block "$NOTE" 11)"
check_output "the template's tag falls back to appVersion (from the note)" \
  'tag \| default \.Chart\.AppVersion' run "$(note_block "$NOTE" 12)"
check_output "appVersion is 1.16.0 (from the note)" '^appVersion: "1.16.0"$' run "$(note_block "$NOTE" 13)"
check_output "with no image.tag, the default is used" 'image: "nginx:1.16.0"' helm template helmcoins

section "Troubleshooting readiness"
# Wait until the probes have run a few times.
retry 180 bash -c '[ "$(kubectl get pods --no-headers | grep -c " 1/1 ")" -ge 2 ]' || true
sleep 60
check_output "hasher and rng are ready; redis, worker and webui are not (from the note)" \
  '^hasher=1/1 redis=0/1 rng=1/1 webui=0/1 worker=0/1$' pods_ready
check_output "redis fails its probes (from the note)" 'Liveness probe failed|Readiness probe failed' \
  run "$(note_block "$NOTE" 15)"
check_output "the original selector app.kubernetes.io/name=redis finds nothing (the correction)" \
  'No resources found' kubectl describe pod -l app.kubernetes.io/name=redis

section "Healthchecks"
check "the note's {{- with }} snippet is in the generated template" \
  in_file helmcoins/templates/deployment.yaml "$(note_block "$NOTE" 16)"
check_output "the probes are defined in values.yaml" '^livenessProbe:' cat helmcoins/values.yaml

section "Removing the healthchecks"
for c in redis worker; do note_block "$NOTE" 17 >>"$c.yaml"; done
check "upgrade with the values files (from the note)" run "$(note_block "$NOTE" 18)"
check_output "redis has no probes any more" '^$' \
  kubectl get deploy redis-helmcoins -o jsonpath='{.spec.template.spec.containers[0].livenessProbe}'
check_output "but hasher keeps them" 'httpGet' \
  kubectl get deploy hasher-helmcoins -o jsonpath='{.spec.template.spec.containers[0].livenessProbe}'
retry 180 bash -c '[ "$(kubectl get pods --no-headers | grep -E "^(redis|worker)-" | grep -c " 1/1 ")" -eq 2 ]' || true
check_output "redis and worker are now 1/1 READY (from the note)" 'redis=1/1 .*worker=1/1' pods_ready

section "What's next? Checking services"
retry 120 bash -c 'kubectl logs deploy/worker-helmcoins --tail=20 | grep -q "Error"' || true
check_output "the worker can't resolve redis (from the note, with kubectl logs)" \
  'Error -?[0-9]+ connecting to redis:6379' kubectl logs deploy/worker-helmcoins --tail=20
check_output "services are named COMPONENT-helmcoins (from the note)" '^redis-helmcoins ' \
  run "$(note_block "$NOTE" 21)"
check_output "fullname is defined in _helpers.tpl (from the note)" '_helpers.tpl:.*define "helmcoins.fullname"' \
  run "$(note_block "$NOTE" 22)"

section "Changing service names"
check "the Service template uses include helmcoins.fullname" grep -q 'name: {{ include "helmcoins.fullname" . }}' \
  helmcoins/templates/service.yaml
sed -i 's/^  name: {{ include "helmcoins.fullname" . }}/  name: {{ .Release.Name }}/' helmcoins/templates/service.yaml
check "upgrade all releases (the loop from the note)" run "$(note_block "$NOTE" 18)"
check_output "services now have the right names" '^hasher redis rng webui worker$' \
  bash -c "kubectl get svc -o jsonpath='{.items[*].metadata.name}' | xargs -n1 | sort | xargs"

section "Port numbers"
check "the note's Service ports snippet is in the template" in_file helmcoins/templates/service.yaml "$(note_block "$NOTE" 23)"
check "the note's Deployment ports snippet is in the template (the correction)" \
  in_file helmcoins/templates/deployment.yaml "$(note_block "$NOTE" 24)"
note_block "$NOTE" 25 >>redis.yaml
check "upgrade redis with its port (from the note)" run "$(note_block "$NOTE" 26)"
check_output "service and container both on 6379" '^6379 6379$' bash -c \
  "echo \$(kubectl get svc redis -o jsonpath='{.spec.ports[0].port}') \$(kubectl get deploy redis-helmcoins -o jsonpath='{.spec.template.spec.containers[0].ports[0].containerPort}')"

section "Apply changes"
kubectl rollout status deploy/redis-helmcoins --timeout=180s >/dev/null
kubectl rollout restart deploy/worker-helmcoins >/dev/null
kubectl rollout status deploy/worker-helmcoins --timeout=180s >/dev/null
retry 120 bash -c 'kubectl logs deploy/worker-helmcoins --tail=20 | grep -q "units of work done"' || true
check_output "the worker is working (from the note)" 'units of work done' kubectl logs deploy/worker-helmcoins --tail=20
retry 120 bash -c '[ "$(kubectl get pods --no-headers | grep -E "^webui-" | grep -c " 1/1 ")" -eq 1 ]' || true
check_output "and webui, which needed redis, is ready too" 'webui=1/1' pods_ready
