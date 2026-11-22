#!/usr/bin/env bash
# note: kubernetes/security/kyverno-ingress.md
# env: kind
# timeout: 2400
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
source "$NOTES_ROOT/tests/kubernetes/security/kyverno-lib.bash"

NOTE=kubernetes/security/kyverno-ingress
DOCS_POLICY=https://raw.githubusercontent.com/kyverno/policies/release-1.16/other/unique-ingress-host-and-path/unique-ingress-host-and-path.yaml
use_test_namespace
WORK=$(mktemp -d)
cd "$WORK"
cleanup() { kubectl delete ingress --all --wait=false >/dev/null 2>&1 || true; kyverno_cleanup; _k8s_exit; }
trap '_k8s_rc=$?; cleanup' EXIT
denied() { ! "$@" >"$WORK/out" 2>&1 && grep -q 'denied the request\|blocked due to' "$WORK/out"; }
ing() { kubectl create ingress "$1" --rule="$2=web:80"; }
load() { kubectl apply -f "$1" >/dev/null 2>&1; kubectl wait --for=condition=Ready clusterpolicy/unique-ingress-host-and-path --timeout=120s >/dev/null; }

check "Kyverno is installed (as in kubernetes/security/kyverno)" kyverno_install
kyverno_wait

section "Good news, everyone"
curl -fsSL "$DOCS_POLICY" >docs-policy.yaml
# "remember to switch the validationFailureAction to Enforce for easier testing"
sed -i 's/validationFailureAction: Audit/validationFailureAction: Enforce/' docs-policy.yaml
check "the documentation's policy loads, switched to Enforce" load docs-policy.yaml
check "a first Ingress is accepted" ing first a.example.com/
check "an identical host+path is denied: the basic case works" denied ing second a.example.com/

section "Problem - no host"
check "an Ingress without host is denied" denied ing nohost /
assert_match "by a JMESPath error, as the note shows" 'Unknown key "host" in path' "$(cat "$WORK/out")"

section "Problem - no UPDATE"
check "a no-op edit of an existing Ingress (a label) is denied: it conflicts with itself" \
  denied kubectl label ingress first touched=yes

section "Problem - poor UX"
denied ing third a.example.com/ || true
assert_match "the message is the policy's fixed text" \
  'The Ingress host and path combination must be unique across the cluster' "$(cat "$WORK/out")"
assert_no_match "it does not say which Ingress conflicts" "'first'|ingress/first|Ingress first" "$(cat "$WORK/out")"

section "Problem - useless block"
# Without the DELETE precondition, deleting is still fine: match only covers CREATE and UPDATE.
awk '/preconditions:/{skip=1} skip && /context:/{skip=0} !skip' docs-policy.yaml >no-precondition.yaml
assert_no_match "the precondition is gone" 'preconditions' "$(cat no-precondition.yaml)"
check "the policy loads without it" load no-precondition.yaml
check "and deleting an Ingress is not blocked" kubectl delete ingress first

section "Solution - no host + Solution - no UPDATE"
{
  sed -n '1,/^spec:/p' docs-policy.yaml
  cat <<'EOF'
  validationFailureAction: Enforce
  background: false
  rules:
    - name: check-host-path-combo
      match:
        any:
        - resources:
            kinds:
              - Ingress
EOF
  note_block "$NOTE" 'Solution - no UPDATE' 1 | reindent 6
  cat <<'EOF'
      validate:
        message: "The Ingress host and path combination must be unique across the cluster."
        foreach:
        - list: "request.object.spec.rules[]"
          deny:
            conditions:
              all:
              - key: "{{ element.http.paths[].path }}"
                operator: AnyIn
                value: "{{ ingresses[].spec.rules[] | [?host=='{{element.host||''}}'][].http.paths[].path }}"
EOF
} >fixed.yaml
check "the fixed policy (the note's context, and element.host||'') loads" load fixed.yaml
check "an Ingress is accepted" ing first a.example.com/
check "an identical one is still denied" denied ing second a.example.com/
check "an Ingress without host is now accepted" ing nohost /
check "a no-op edit is now accepted" kubectl label ingress first touched=yes
check "host1/path1 and host2/path2 do not conflict with host1/path2" \
  bash -c 'kubectl create ingress multi --rule=b.example.com/one=web:80 --rule=c.example.com/two=web:80 &&
           kubectl create ingress cross --rule=b.example.com/two=web:80'
