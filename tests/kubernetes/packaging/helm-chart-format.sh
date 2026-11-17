#!/usr/bin/env bash
# note: kubernetes/packaging/helm-chart-format.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/packaging/helm-chart-format
CHART=oci://ghcr.io/securecodebox/helm/juice-shop
use_test_namespace
HOME=$(mktemp -d)
export HOME
cd "$HOME"
run() { bash -ec "$1" 2>&1; }

section "Downloading a chart"
check_fails "the old repository is gone (the correction)" helm repo add juice https://charts.securecodebox.io
check "helm pull (from the note)" run "$(note_block "$NOTE" 1)"
check "it creates juice-shop-X.Y.Z.tgz" bash -c 'ls juice-shop-*.*.*.tgz'
check "helm pull --untar (from the note)" run "$(note_block "$NOTE" 2)"
check "it creates the juice-shop directory" test -d juice-shop

section "Looking at the chart's content"
tree_out=$(run "$(note_block "$NOTE" 3)")
for f in Chart.yaml values.yaml templates README.md NOTES.txt; do
  assert_match "tree shows $f (from the note)" "$f" "$tree_out"
done

section "Templates"
svc=$(run "$(note_block "$NOTE" 4)")
assert_match "the Service template has template tags" '\{\{' "$svc"
assert_match "it uses .Values" '\.Values\.service' "$svc"
assert_match "and named templates" '(include|template) "juice-shop\.' "$svc"

section "What's in a chart (the correction)"
mkdir -p mini
printf 'apiVersion: v2\nname: mini\nversion: 0.1.0\n' >mini/Chart.yaml
check "Chart.yaml alone: helm lint passes" helm lint mini
check_output "helm template renders it, empty" '^$' helm template x mini
rm mini/Chart.yaml
mkdir mini/templates
check_fails "without Chart.yaml, it is not a chart" helm lint mini

section "Tags, pipelines, files"
mkdir -p tags/templates tags/files
printf 'apiVersion: v2\nname: tags\nversion: 0.1.0\n' >tags/Chart.yaml
cat >tags/values.yaml <<'EOF'
annotations: {team: blue, tier: web}
items: [a, b]
on: true
EOF
echo 'hello from a file' >tags/files/greeting.txt
cat >tags/templates/cm.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: tags
  annotations:
{{ .Values.annotations | toYaml | indent 4 }}
data:
  quoted: {{ quote "a b" }}
  piped: {{ "a b" | quote }}
  multi: {{ indent 2 "x" | quote }}
  multipiped: {{ "x" | indent 2 | quote }}
  {{- if .Values.on }}
  cond: "yes"
  {{- end }}
  {{- range .Values.items }}
  item-{{ . }}: "1"
  {{- end }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: files
data:
{{ (.Files.Glob "files/*").AsConfig | indent 2 }}
EOF
out=$(helm template t tags 2>&1)
assert_match "toYaml | indent 4 turns the map into indented YAML" $'\n    team: blue\n    tier: web' "$out"
assert_match "{{ quote x }}" 'quoted: "a b"' "$out"
assert_match "is {{ x | quote }}" 'piped: "a b"' "$out"
assert_match "{{ x y z }} is {{ z | x y }}" 'multi: "  x"' "$out"
assert_match "(same output)" 'multipiped: "  x"' "$out"
assert_match "if includes a block when true; {{- trims the newline before" $'\n  cond: "yes"' "$out"
assert_match "range iterates, with the element as ." $'item-a: "1"\n  item-b: "1"' "$out"
assert_match ".Files.Glob ... AsConfig turns files into ConfigMap data" $'greeting.txt: |\n    hello from a file' "$out"

section "README, NOTES.txt, hooks and tests"
check_output "helm show readme (from the note)" 'Juice Shop' helm show readme "$CHART"
check_output "NOTES.txt is rendered and shown after install" 'Get the application URL' \
  helm install juice "$CHART" --wait --timeout 5m
check_output "the chart's test is a hook" 'helm.sh/hook.*test' cat juice-shop/templates/tests/test-connection.yaml
check_output "it runs only with helm test" 'Phase: +Succeeded' helm test juice
