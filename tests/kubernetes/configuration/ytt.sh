#!/usr/bin/env bash
# note: kubernetes/configuration/ytt.md
# env: kind
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/configuration/ytt
# Not in versions.env yet (shared file): pinned here.
YTT_VERSION=v0.55.4
cd "$(mktemp -d)"
case $(uname -m) in x86_64) arch=amd64 ;; aarch64 | arm64) arch=arm64 ;; esac
mkdir bin
export PATH=$PWD/bin:$PATH
curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 -o bin/ytt \
  "https://github.com/carvel-dev/ytt/releases/download/$YTT_VERSION/ytt-linux-$arch"
chmod +x bin/ytt

# block HEADING [N]: write the note's block to a file named after the heading, print its name.
block() {
  local f
  f=$(tr -c 'a-zA-Z0-9\n' _ <<<"$1$2").yaml
  note_block "$NOTE" "$1" "${2:-1}" >"$f"
  echo "$f"
}
run() { ytt -f "$(block "$@")"; }

section "Getting started"
kubectl create configmap one --from-literal=a=b --dry-run=client -o yaml >one.yaml
kubectl create configmap two --from-literal=c=d --dry-run=client -o yaml >two.yaml
check "ytt -f one.yaml -f two.yaml | kubectl apply -f-" bash -c 'ytt -f one.yaml -f two.yaml | kubectl apply -f-'
check "  both ConfigMaps exist" kubectl get configmap one two
mkdir dir && mv one.yaml two.yaml dir/
check "ytt -f. | kubectl apply -f- (a whole directory)" bash -c 'cd dir && ytt -f. | kubectl apply -f-'
printf 'a: 1 # comment\n# full-line comment\nb: 2\n' >comments.yaml
check_output "correction: ytt $YTT_VERSION accepts plain # comments" '^b: 2$' ytt -f comments.yaml
check_fails "  and drops them from the output" bash -c 'ytt -f comments.yaml | grep -q comment'

section "No comments?!?"
check_output "#@ code and values; 42 * \"*\" is 42 stars" "^result: '\*{42}'\$" run 'No comments?!?'
check_output "  #! comments are dropped" '^a: 42$' run 'No comments?!?'

section "Building strings"
check_output "concatenation" '^  image: dockercoins/worker:v0.1$' run 'Building strings' 1
check_output "formatting" '^  image: dockercoins/worker:v0.1$' run 'Building strings' 2

section "Defining functions"
check_output "a Starlark function" '^  image: dockercoins/hasher:v0.1$' run 'Defining functions'

section "Structured data"
check_output "a function returning a dict" '^    container.training/generated-by: ytt$' run 'Structured data'
check_output "  app label" '^    app: worker$' run 'Structured data'
check "  the Pod is a valid manifest" bash -c "ytt -f $(block 'Structured data') | sed 's/^kind: Pod/&\nspec: {containers: [{name: w, image: alpine}]}/' | kubectl apply --dry-run=server -f-"

section "YAML functions"
check_output "a YAML fragment function gives the same labels" '^    container.training/generated-by: ytt$' run 'YAML functions'

section "More YAML functions"
check "load(@ytt:sha256)" run 'More YAML functions' 1
hash=$(printf '%s' 'Jérôme Petazzoni' | sha256sum | cut -c1-8)
check_output "a mix of code and YAML: author_hash is sha256[:8] ($hash)" "^  author_hash: \"?$hash\"?\$" run 'More YAML functions' 2

section "Data values"
mkdir config
note_block "$NOTE" 'Data values' 1 >config/schema.yaml
note_block "$NOTE" 'Using data values' 1 >config/template.yaml
check_output "the schema defaults" '^  image: dockercoins/worker:v0.1$' ytt -f config/
check_output "types are enforced: a number for tag fails" 'expected: string' bash -c 'ytt -f config/ --data-value-yaml tag=1 2>&1; true'
check_fails "  (and exits non-zero)" ytt -f config/ --data-value-yaml tag=1

section "Values in plain YAML files"
note_block "$NOTE" 'Values in plain YAML files' 1 >values.yaml
check_output "--data-values-file (from the note)" '^  image: dockercoins/worker:latest$' bash -ec "$(note_block "$NOTE" 'Values in plain YAML files' 2)"

section "Data value overlay"
note_block "$NOTE" 'Data value overlay' 1 >values.yaml
check_output "a #@data/values file (from the note)" '^  image: dockercoins/worker:latest$' bash -ec "$(note_block "$NOTE" 'Data value overlay' 2)"

section "Set a value with a flag"
check_output "--data-value (from the note)" '^  image: dockercoins/worker:latest$' bash -ec "$(note_block "$NOTE" 'Set a value with a flag' 1)"
check_output "--data-value-yaml fails for a value not in the schema" 'replicas' bash -c "$(note_block "$NOTE" 'Set a value with a flag' 2) 2>&1; true"
# Add the two values to the schema, and a template that shows them.
printf 'replicas: 1\nca_cert: ""\n' >>config/schema.yaml
printf -- '#@ load("@ytt:data", "data")\n---\nreplicas: #@ data.values.replicas\nca_cert: #@ data.values.ca_cert\n' >config/more.yaml
check_output "with replicas in the schema, --data-value-yaml gives an integer" '^replicas: 10$' bash -ec "$(note_block "$NOTE" 'Set a value with a flag' 2)"
check_output "  while --data-value gives a string, refused by the schema" 'replicas' bash -c 'ytt -f config/ --data-value replicas=10 2>&1; true'
echo 'PEM DATA' >cert.pem
check_output "--data-value-file (from the note)" '^ca_cert: \|' bash -ec "$(note_block "$NOTE" 'Set a value with a flag' 3)"

section "Set values from environment variables"
envs=$(note_block "$NOTE" 'Set values from environment variables' 1)
check_output "--data-values-env (from the note)" '^  image: ghcr.io/dockercoins/worker:latest$' \
  bash -ec "$envs; $(note_block "$NOTE" 'Set values from environment variables' 2)"
check_output "--data-values-env-yaml (from the note)" '^replicas: 3$' \
  bash -ec "$envs; export VAL_replicas=3; $(note_block "$NOTE" 'Set values from environment variables' 3)"

section "Lines starting with #@"
check_output "#@ hello() alone gives an empty document" '^$' run 'Lines starting with' 1
check_output "--- #@ hello() works" '^hello: world$' run 'Lines starting with' 2

section "Generating multiple documents, take 1"
check_fails "take 1 fails" run 'take 1'
section "Generating multiple documents, take 2"
check_output "take 2 fails: this is a document set" 'documents can only contain arrays, maps, or scalars; this is a document set' bash -c "ytt -f $(block 'take 2') 2>&1; true"
check_fails "  (and exits non-zero)" run 'take 2'
section "Generating multiple documents, take 3"
check_output "template.replace gives two documents" '^2$' bash -c "ytt -f $(block 'take 3') | grep -c '^kind:'"

section "Libraries"
mkdir -p lib/_ytt_lib/whatever
printf '#@data/values-schema\n---\ntag: v0.1\nregistry: docker.io\n' >lib/_ytt_lib/whatever/schema.yaml
printf -- '#@ load("@ytt:data", "data")\n---\nkind: Pod\nimage: #@ data.values.registry + "/worker:" + data.values.tag\n' >lib/_ytt_lib/whatever/pod.yaml
note_block "$NOTE" 'Libraries' 1 >lib/main.yaml
check_output "library.get(...).with_data_values(...).eval()" "^image: '?\.\.\./worker:latest'?$" ytt -f lib/

section "Example"
cat >deployments.yaml <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: {name: worker}
spec: {replicas: 1}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: hasher, annotations: {team: blue}}
spec: {replicas: 1}
YAML
overlay() { ytt -f deployments.yaml -f "$(block "$@")"; }
check_output "the subset overlay sets replicas: 10 on worker" '^  replicas: 10$' overlay 'Example'
check_output "  and only on worker" '^1$' bash -c "ytt -f deployments.yaml -f $(block 'Example') | grep -c 'replicas: 10'"
check_output "exactly one match is required by default" 'Expected number of matched nodes to be 1, but was 0' \
  bash -c "sed 's/name: worker/name: nothere/' deployments.yaml >d0.yaml; ytt -f d0.yaml -f $(block 'Example') 2>&1; true"
printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata: {name: worker}\nspec: {}\n' >noreplicas.yaml
check_fails "the fields must exist by default" bash -c "ytt -f noreplicas.yaml -f $(block 'Example')"

section "Matching using a YAML document"
check_output "same result with a YAML document matcher" '^  replicas: 10$' overlay 'Matching using a YAML document'

section "Removing a field"
check_output "overlay/remove removes replicas from worker only" '^1$' bash -c "ytt -f deployments.yaml -f $(block 'Removing a field') | grep -c 'replicas:'"

section "Selecting multiple nodes"
check_output "expects=1+ removes replicas from all Deployments" '^0$' bash -c "ytt -f deployments.yaml -f $(block 'Selecting multiple nodes') | grep -c 'replicas:' || true"

section "Adding a field"
check_output "the annotation is added with or without annotations" '^2$' bash -c "ytt -f deployments.yaml -f $(block 'Adding a field') | grep -c 'rainbow:'"
check_output "  and team: blue is kept" '^    team: blue$' overlay 'Adding a field'
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: c\n  annotations: {rainbow: "yes"}\n' >hasrainbow.yaml
check_fails "expects=0: an existing rainbow annotation makes ytt fail" bash -c "ytt -f hasrainbow.yaml -f $(block 'Adding a field')"

section "Gotchas"
check_output "--- #@ on the same line: hello, world!" '^hello, world!$' run 'Gotchas' 1
check_output "#@ on the next line: an empty document" '^$' run 'Gotchas' 2
printf -- '#@ load("@ytt:template", "template")\n--- #@ template.render([1])\n' >render.yaml
check_output "correction: there is no template.render" 'module has no .render field or method' bash -c 'ytt -f render.yaml 2>&1; true'
