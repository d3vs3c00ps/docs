#!/usr/bin/env bash
# note: kubernetes/packaging/helm-dependencies.md
# env: kind
# timeout: 1200
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/packaging/helm-dependencies
use_test_namespace
HOME=$(mktemp -d)
export HOME
cd "$HOME"
run() { bash -ec "$1" 2>&1; }
# nb ARGS: a note block, without the list indentation it has in the note.
nb() { note_block "$NOTE" "$@" | awk 'NR == 1 { match($0, /^ */); n = RLENGTH } { print substr($0, n + 1) }'; }
# kinds_names: "Kind/name" of every resource helm template renders, sorted.
kinds_names() { helm template "$@" | awk '/^kind:/{k=$2} /^  name:/{if(k){print k"/"$2; k=""}}' | sort -u; }

helm create helmcoins >/dev/null
cd helmcoins

section "Declaring the dependency"
dep=$(nb 'Declaring the dependency' 1)
assert_match "the note pins the chart version the tests use" "version: $BITNAMI_REDIS_CHART" "$dep"
check_output "the old version 11.0.5 is gone from the index (the correction)" 'not found' bash -c \
  "helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null && helm pull bitnami/redis --version 11.0.5 2>&1 || true"
echo "$dep" >>Chart.yaml

section "Lock & Load!"
check "helm dependency update (from the note)" run "$(note_block "$NOTE" 'Lock & Load' 1)"
check_output "it creates Chart.lock with the exact version" "version: $BITNAMI_REDIS_CHART" cat Chart.lock
check "and fetches the dependency, compressed, into charts/" test -f "charts/redis-$BITNAMI_REDIS_CHART.tgz"
rm -r charts
check "helm dependency build fetches what Chart.lock lists" helm dependency build
check "(the same file)" test -f "charts/redis-$BITNAMI_REDIS_CHART.tgz"
check_output "the chart's default image is bitnami/redis:latest" 'image: registry-1.docker.io/bitnami/redis:latest' \
  helm template helmcoins .

section "Conditions"
check_output "with the dependency, redis resources are rendered" 'StatefulSet/helmcoins-redis-master' kinds_names helmcoins .
assert_no_match "--set redis.enabled=false removes them" 'redis' "$(kinds_names helmcoins . --set redis.enabled=false)"

section "Loose dependencies"
(
  mkdir -p ../loose
  printf 'apiVersion: v2\nname: loose\nversion: 0.1.0\n' >../loose/Chart.yaml
  nb 'Loose dependencies' 1 >>../loose/Chart.yaml
  cd ../loose && helm dependency update >/dev/null
)
check_output "\">=28, <29\" locks the newest 28.x" '^  version: 28\.' cat ../loose/Chart.lock

section "Dependency tuning"
check_output "by default the Service is <release>-redis-master, not redis" '^Service/helmcoins-redis-master$' \
  kinds_names helmcoins .
(cd charts && tar zxf "redis-$BITNAMI_REDIS_CHART.tgz")
check_output "the Service template (from the note)" 'printf "%s-master" \(include "common.names.fullname" \.\)' \
  grep -h 'name:' charts/redis/templates/master/service.yaml
def=$(note_block "$NOTE" 'Dependency tuning' 1 | grep -v '\[\.\.\.\]')
check "the note's common.names.fullname excerpt matches the common chart" bash -c \
  'while read -r l; do grep -qF -- "$l" charts/redis/charts/common/templates/_names.tpl || { echo "missing: $l"; exit 1; }; done' <<<"$def"
rm -r charts/redis

section "Setting dependency variables"
nb 'Setting dependency variables' 1 >>values.yaml
rendered=$(kinds_names helmcoins .)
assert_match "fullnameOverride: the Service is redis-master" '^Service/redis-master$' "$rendered"
assert_no_match "architecture: standalone: no replicas" 'redis-replicas' "$rendered"
assert_no_match "auth.enabled: false: no password Secret" '^Secret/redis$' "$rendered"
check_output "the old cluster.enabled is not a value of this chart any more (the correction)" '^$' \
  bash -c "helm show values charts/redis-$BITNAMI_REDIS_CHART.tgz | grep -E '^cluster:' || true"

section "Embedding a dependency"
check "decompress the chart (from the note)" run "$(note_block "$NOTE" 'Embedding a dependency' 1)"
check_output "only the folder is left in charts/ (the correction)" '^redis$' ls charts
# Replace the dependencies section with the note's local one.
sed -i '/^dependencies:/,$d' Chart.yaml
nb 'Embedding a dependency' 2 >>Chart.yaml
check "helm dep update with the local copy" helm dependency update
check_output "(and it does not bring the archive back)" '^redis$' ls charts
check_output "the embedded chart is used" "redis.*\*.*|version: '\*'" cat Chart.yaml
check "the Service template is where the note says" test -f charts/redis/templates/master/service.yaml
sed -i 's/{{ printf "%s-master" (include "common.names.fullname" .) }}/{{ include "common.names.fullname" . }}/' \
  charts/redis/templates/master/service.yaml
check_output "after the edit, the Service is named redis" '^Service/redis$' kinds_names helmcoins .

section "Updating the dependency: deploy the whole chart"
check "helm install of the whole chart" helm install helmcoins . --wait --timeout 6m
check_output "a redis Service, as DockerCoins expects" '^redis ' kubectl get svc --no-headers
check_output "redis answers, without a password" 'PONG' \
  kubectl exec redis-master-0 -- redis-cli -h redis ping

section "Embedding a dependency multiple times"
nb 'multiple times' 1 >alias.yaml
sed -i '/^dependencies:/,$d' Chart.yaml
cat alias.yaml >>Chart.yaml
cat >>values.yaml <<'EOF'
querycache: {architecture: standalone, auth: {enabled: false}}
celeryqueue: {architecture: standalone, auth: {enabled: false}}
EOF
printf 'chart: {{ .Chart.Name }}\nroot: {{ .Chart.IsRoot }}\n' >charts/redis/templates/z-name.txt
mv charts/redis/templates/z-name.txt charts/redis/templates/z-name.yaml
out=$(helm template helmcoins . --show-only charts/querycache/templates/z-name.yaml --show-only charts/celeryqueue/templates/z-name.yaml 2>&1)
assert_match ".Chart.Name is the alias" 'chart: querycache' "$out"
assert_match "(both aliases)" 'chart: celeryqueue' "$out"
assert_match ".Chart.IsRoot is false in a subchart" 'root: false' "$out"
printf 'root: {{ .Chart.IsRoot }}\n' >templates/z-root.yaml
check_output ".Chart.IsRoot is true in the top-level chart" 'root: true' \
  helm template helmcoins . --show-only templates/z-root.yaml

section "Compatibility with Helm 2"
mkdir -p ../v1
printf 'apiVersion: v1\nname: v1\nversion: 0.1.0\n' >../v1/Chart.yaml
printf 'dependencies:\n- name: redis\n  version: %s\n  repository: https://charts.bitnami.com/bitnami\n' \
  "$BITNAMI_REDIS_CHART" >../v1/requirements.yaml
check "a v1 chart with requirements.yaml still works with Helm 4" bash -c 'cd ../v1 && helm dependency update'
check "and gets a requirements.lock" test -f ../v1/requirements.lock
