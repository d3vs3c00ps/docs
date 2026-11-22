#!/usr/bin/env bash
# note: kubernetes/configuration/kustomize.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/configuration/kustomize
# Not in versions.env yet (shared file): pinned here.
KUSTOMIZE_VERSION=v5.8.3
# The upstream example files the note quotes, at the commit the note is derived from.
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/kustomize-examples

cd "$(mktemp -d)"
export HOME=$PWD
WORK=$PWD
fetch() { curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 "$@"; }
case $(uname -m) in x86_64) arch=amd64 ;; aarch64 | arm64) arch=arm64 ;; esac
mkdir bin
export PATH=$WORK/bin:$PATH
fetch "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/$KUSTOMIZE_VERSION/kustomize_${KUSTOMIZE_VERSION}_linux_$arch.tar.gz" | tar -xz -C bin kustomize

# new_dir NAME: an empty directory to build a kustomization in.
new_dir() { rm -rf "${WORK:?}/$1" && mkdir -p "$WORK/$1" && cd "$WORK/$1"; }
images() { kustomize build . | sed -n 's/^ *- image: //p' | tr '\n' ' '; }

section "A simple kustomization"
new_dir simple
note_block "$NOTE" 'A simple kustomization' 1 >kustomization.yaml
note_block "$NOTE" 'A simple kustomization' 2 >scale-deployment.yaml
kubectl create deployment web --image=nginx --dry-run=client -o yaml >deployment.yaml
kubectl create service clusterip web --tcp=80 --dry-run=client -o yaml >service.yaml
kubectl create ingress web --rule='www.example.com/*=web:80' --dry-run=client -o yaml >ingress.yaml
cat >ingress-hostname.yaml <<'YAML'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
spec:
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend: {service: {name: web, port: {number: 80}}}
YAML
check "kustomize build (the note's kustomization)" kustomize build .
check_output "the scale patch (from the note) sets 3 replicas" 'replicas: 3' kustomize build .
check_output "the Ingress hostname is patched" 'host: app.example.com' kustomize build .
check "kubectl kustomize gives the same output as kustomize build" bash -c 'diff <(kustomize build .) <(kubectl kustomize .)'
check "kubectl apply -k ." kubectl apply -k .
check_output "the Deployment, Service and Ingress exist" '3' \
  bash -c 'kubectl get deploy/web svc/web ingress/web --no-headers | wc -l'

section "A more complex Kustomization"
new_dir complex
skip "the two github.com/example remote resources" "placeholder repositories; remote bases are tested under 'Remote bases'"
note_block "$NOTE" 'A more complex Kustomization' 1 | sed '/github.com\/example/d' >kustomization.yaml
mkdir db workers
kubectl create deployment db --image=postgres --dry-run=client -o yaml >db/db.yaml
printf 'resources:\n- db.yaml\n' >db/kustomization.yaml
cat >workers/workers.yaml <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: worker
spec:
  selector: {matchLabels: {app: worker}}
  template:
    metadata: {labels: {app: worker}}
    spec:
      containers:
      - name: worker
        image: dockercoins/worker:v0.1
        volumeMounts: [{name: config, mountPath: /config}]
      volumes:
      - name: config
        configMap: {name: appconfig}
YAML
printf 'resources:\n- workers.yaml\n' >workers/kustomization.yaml
kubectl create ingress front --rule='www.example.com/*=front:80' --dry-run=client -o yaml >ingress.yaml
kubectl create serviceaccount app --dry-run=client -o yaml >rbac.yaml
echo 'global=1' >global.conf
echo 'env=prod' >prod.conf
printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: worker\nspec:\n  template:\n    spec:\n      containers:\n      - name: worker\n        livenessProbe: {exec: {command: ["true"]}}\n' >healthchecks.yaml
printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: worker\nspec:\n  template:\n    spec:\n      containers:\n      - name: worker\n        resources: {requests: {cpu: 10m}}\n' >resources-requests-and-limits.yaml
kustomize build . >out.yaml
objs() { kubectl create -f out.yaml --dry-run=client -o json | jq -rs "$1"; }
check_output "commonAnnotations is on every resource" '^1 Bump libfoo to version 1.2.3$' \
  objs '[.[].metadata.annotations["last-commit-message"]] | unique | "\(length) \(.[0])"'
check_output "labels adds last-commit-hash" 'last-commit-hash: 39bc2d' cat out.yaml
check_output "configMapGenerator: appconfig-<hash>" 'name: appconfig-[a-z0-9]{10}$' cat out.yaml
check_output "local.conf has the content of prod.conf" 'local.conf: \|' cat out.yaml
check_output "  (env=prod)" '^env=prod$' objs '.[] | select(.kind == "ConfigMap") | .data["local.conf"]'
check_output "the Deployment refers to the hashed ConfigMap name" '^appconfig-[a-z0-9]{10}$' \
  objs '.[] | select(.metadata.name == "worker") | .spec.template.spec.volumes[0].configMap.name'
check_output "both patches apply to the worker" 'livenessProbe' cat out.yaml
check_output "  (requests too)" 'cpu: 10m' cat out.yaml
check "the result passes server-side validation" kubectl apply --dry-run=server -f out.yaml

section "kustomize create"
# The original URL, without ?ref=: the default branch has no kustomization.yaml.
new_dir orig-url
kustomize create --resources https://github.com/jpetazzo/kubercoins
check_output "without ?ref=kustomize, kustomize build fails" "unable to find one of 'kustomization.yaml'" \
  bash -c 'kustomize build . 2>&1; true'
cd "$WORK"
check "the hands-on: mkdir, kustomize create, build | apply (from the note)" bash -ec "
$(note_block "$NOTE" 'kustomize create' 1)
$(note_block "$NOTE" 'kustomize create' 2)
$(note_block "$NOTE" 'kustomize create' 3)"
check_output "the kustomization lists the remote resource" 'kubercoins\?ref=kustomize' cat ~/kustomcoins/kustomization.yaml
check_output "the 5 DockerCoins Deployments are created" '^5$' bash -c 'kubectl get deploy hasher redis rng webui worker --no-headers | wc -l'

section "kubectl integration"
check_output "kubectl 1.37 includes Kustomize 5.8" '^Kustomize Version: v5\.8\.' kubectl version --client
check "kubectl delete -k (commands that take -f also take -k)" kubectl delete -k "$WORK/simple"

section "Kustomization basics"
new_dir basics
kubectl create deployment web --image=nginx --dry-run=client -o yaml >d.yaml
printf 'resources:\n- d.yaml\ncommonLabels:\n  team: blue\n' >kustomization.yaml
check_output "commonLabels is deprecated (warning)" "'commonLabels' is deprecated. Please use 'labels'" bash -c 'kustomize build . 2>&1 >/dev/null'
check "kustomize edit fix rewrites it" kustomize edit fix
check_output "  into labels" '^labels:' cat kustomization.yaml
mkdir -p base && mv d.yaml base/ && printf 'resources:\n- d.yaml\n' >base/kustomization.yaml
printf 'bases:\n- base\n' >kustomization.yaml
check_output "bases is deprecated (warning)" "'bases' is deprecated. Please use 'resources'" bash -c 'kustomize build . 2>&1 >/dev/null'
printf 'secretGenerator:\n- name: creds\n  literals:\n  - password=s3cr3t\n' >kustomization.yaml
check_output "secretGenerator adds a hash to the name" 'name: creds-[a-z0-9]{10}$' kustomize build .
printf 'generatorOptions:\n  disableNameSuffixHash: true\nsecretGenerator:\n- name: creds\n  literals:\n  - password=s3cr3t\n' >kustomization.yaml
check_output "generatorOptions can turn the hash off" 'name: creds$' kustomize build .

section "Transforming resources"
printf 'resources:\n- base\npatchesStrategicMerge:\n- p.yaml\n' >kustomization.yaml
printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: web\nspec:\n  replicas: 2\n' >p.yaml
check_output "patchesStrategicMerge is deprecated (warning)" "'patchesStrategicMerge' is deprecated. Please use 'patches'" bash -c 'kustomize build . 2>&1 >/dev/null'
printf 'resources:\n- base\npatchesJson6902:\n- target: {group: apps, version: v1, kind: Deployment, name: web}\n  patch: |-\n    - op: remove\n      path: /spec/strategy\n' >kustomization.yaml
check_output "patchesJson6902 is deprecated (warning)" "'patchesJson6902' is deprecated. Please use 'patches'" bash -c 'kustomize build . 2>&1 >/dev/null'
printf 'resources:\n- base\npatches:\n- target: {kind: Deployment}\n  patch: |-\n    - op: replace\n      path: /spec/replicas\n      value: 4\n' >kustomization.yaml
check_output "an inline patch with a target selection" 'replicas: 4' kustomize build .
printf 'resources:\n- base\nnamePrefix: dev-\nnamespace: dev\nreplicas:\n- name: web\n  count: 2\n' >kustomization.yaml
check_output "namePrefix, namespace and replicas helpers" 'name: dev-web' kustomize build .

section "Teach Kustomize new tricks"
printf 'resources:\n- base\nvars:\n- name: X\n  objref: {kind: Deployment, name: web, apiVersion: apps/v1}\n' >kustomization.yaml
check_output "vars is deprecated (warning)" "'vars' is deprecated. Please use 'replacements'" bash -c 'kustomize build . 2>&1 >/dev/null'
# A local chart (in chartHome), so no download is needed.
mkdir charts && helm create charts/demo >/dev/null
printf 'helmGlobals:\n  chartHome: charts\nhelmCharts:\n- name: demo\n  releaseName: demo\n' >kustomization.yaml
check_output "helmCharts needs --enable-helm" 'enable-helm' bash -c 'kustomize build . 2>&1; true'
check_output "with --enable-helm, the chart is rendered" 'kind: Deployment' kustomize build --enable-helm .

section "Remote bases"
check_output "the remote base example builds (from the note)" 'name: cluster-a-prod-myapp-pod' bash -ec "$(note_block "$NOTE" 'Remote bases' 1)"
new_dir raw
printf 'resources:\n- https://raw.githubusercontent.com/jpetazzo/kubercoins/master/redis-deployment.yaml\n' >kustomization.yaml
check_output "a plain HTTPS URL to one file works too" 'name: redis' kustomize build .

section "What Kustomize cannot do"
new_dir delete
fetch "$UPSTREAM/registry-with-prefix-transformer/microservices/microservices.yaml" >app.yaml
cat >kustomization.yaml <<'YAML'
resources:
- app.yaml
patches:
- patch: |
    $patch: delete
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: worker
YAML
check_output "a \$patch: delete patch removes a resource" '^0$' bash -c 'kustomize build . | grep -c "name: worker$" || true'

section "Changing images with the CLI"
new_dir cli
fetch "$UPSTREAM/registry-with-prefix-transformer/microservices/microservices.yaml" >microservices.yaml
kustomize create --resources microservices.yaml
mapfile -t cmds < <(note_block "$NOTE" 'Changing images with the CLI' 2)
check "kustomize edit set image, new name (from the note)" bash -ec "${cmds[0]}"
check_output "  sets newName" 'newName: ghcr.io/dockercoins/worker' cat kustomization.yaml
check "kustomize edit set image, new name and tag (from the note)" bash -ec "${cmds[1]}"
check_output "  sets newName and newTag" 'image: ghcr.io/dockercoins/worker:v0.2' kustomize build .
check "kustomize edit set image, tag only (from the note)" bash -ec "${cmds[2]}"
check_output "  replaces the entry: only newTag is left" 'image: dockercoins/worker:v0.2' kustomize build .
check_fails "  newName is gone" grep -q newName kustomization.yaml

section "Changing images with images:"
new_dir images
note_block "$NOTE" 'Changing images with `images:`' 1 >kustomization.yaml
cat >app.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: app
spec:
  containers:
  - {name: db, image: postgres}
  - {name: worker, image: dockercoins/worker:v0.1}
  - {name: hasher, image: dockercoins/hasher:v0.1}
  - {name: sh, image: alpine:3.20}
YAML
check_output "images: changes names, tags and digests (from the note)" \
  '^harbor.example.com/my-postgres dockercoins/worker:v0.2 registry.example.com/hasher:v0.2 alpine@sha256:24a0c4b4' images

section "images: in practice"
new_dir practice
fetch "$UPSTREAM/registry-with-replacements/dockercoins.yaml" >dockercoins.yaml
{ printf 'resources:\n- dockercoins.yaml\nimages:\n'; note_block "$NOTE" 'in practice' 1; } >kustomization.yaml
check_output "four entries move the four dockercoins images, not redis" \
  '^ghcr.io/dockercoins/hasher:v0.1 redis ghcr.io/dockercoins/rng:v0.1 ghcr.io/dockercoins/webui:v0.1 ghcr.io/dockercoins/worker:v0.1 $' images

section "PrefixSuffixTransformer in action"
new_dir prefix
fetch "$UPSTREAM/registry-with-prefix-transformer/microservices/microservices.yaml" >microservices.yaml
fetch "$UPSTREAM/registry-with-prefix-transformer/redis/redis.yaml" >>microservices.yaml
note_block "$NOTE" '`PrefixSuffixTransformer` in action' 1 >kustomization.yaml
check_output "the transformer (from the note) prefixes the dockercoins images" 'ghcr.io/dockercoins/worker:v0.1' images
check_output "but also every other Deployment: ghcr.io/redis" 'ghcr.io/redis ' images

section "Limiting PrefixSuffixTransformer"
sed -i 's|  - path: spec/template/spec/containers/image|&\n    kind: StatefulSet|' kustomization.yaml
check_output "a fieldSpec with a kind limits it to that kind (no Deployment changes)" '^dockercoins/hasher:v0.1 ' images

section "replacements in action"
new_dir replacements
fetch "$UPSTREAM/registry-with-replacements/dockercoins.yaml" >dockercoins.yaml
note_block "$NOTE" '`replacements` in action' 1 >kustomization.yaml
check_output "the replacement (from the note) changes the selected images, not redis" \
  '^ghcr.io/dockercoins/hasher:v0.1 redis ghcr.io/dockercoins/rng:v0.1 ghcr.io/dockercoins/webui:v0.1 ghcr.io/dockercoins/worker:v0.1 $' images
sed -i 's/^      labelSelector: .*/      name: hasher|rng|webui|worker/' kustomization.yaml
check_output "since Kustomize 5.8, name: is a regex selector" \
  '^ghcr.io/dockercoins/hasher:v0.1 redis ghcr.io/dockercoins/rng:v0.1 ' images
sed -i 's/^      name: .*/    reject:\n    - name: redis/' kustomization.yaml
check_output "reject: excludes resources" '^ghcr.io/dockercoins/hasher:v0.1 redis ghcr.io/dockercoins/rng:v0.1 ' images

section "Inconsistencies"
new_dir paths
cat >pod.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: p
spec:
  containers:
  - {name: other, image: alpine}
  - {name: hello, image: alpine}
YAML
cat >kustomization.yaml <<'YAML'
resources:
- pod.yaml
replacements:
- sourceValue: busybox
  targets:
  - select: {kind: Pod}
    fieldPaths:
    - spec.containers.[name=hello].image
YAML
check_output "fieldPaths: containers.[name=hello] picks one container" '^alpine busybox $' images
