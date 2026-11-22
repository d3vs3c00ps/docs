#!/usr/bin/env bash
# note: kubernetes/storage/statefulsets.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/storage/statefulsets
use_test_namespace
cd "$(mktemp -d)"

section "Using a cloud volume, using an NFS volume"
# The examples have `image: ...`; with a real image, the API server accepts them as written.
for n in 1 2; do
  note_block "$NOTE" "$n" | sed 's/image: \.\.\./image: alpine/' >"example-$n.yaml"
done
check "the EBS example is still a valid Pod for the API (the field remains)" \
  kubectl create --dry-run=server -f example-1.yaml
check "the NFS example is a valid Pod" kubectl create --dry-run=server -f example-2.yaml

section "Stateful sets unique features"
# 3 replicas, each Ready 5s after it starts, with a claim template named data.
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Service
metadata: {name: web}
spec:
  clusterIP: None
  selector: {app: web}
  ports: [{port: 80}]
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: web}
spec:
  serviceName: web
  replicas: 3
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web}}
    spec:
      terminationGracePeriodSeconds: 1
      containers:
      - name: c
        image: busybox:1.37
        command: [sh, -c, 'hostname >/data/me; sleep 3600']
        readinessProbe: {exec: {command: [test, -f, /data/me]}, initialDelaySeconds: 5, periodSeconds: 1}
        volumeMounts: [{name: data, mountPath: /data}]
  volumeClaimTemplates:
  - metadata: {name: data}
    spec:
      accessModes: [ReadWriteOnce]
      resources: {requests: {storage: 10Mi}}
EOF
check "the 3 replicas become ready" kubectl rollout status statefulset/web --timeout=300s
check_output "pods are numbered from 0 to R-1" '^web-0 web-1 web-2$' \
  bash -c "kubectl get pods -l app=web -o jsonpath='{.items[*].metadata.name}' | xargs -n1 | sort | xargs"
# Each pod is created only once the previous one is Ready.
ok=yes
for i in 1 2; do
  ready=$(kubectl get pod "web-$((i - 1))" -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastTransitionTime}')
  created=$(kubectl get pod "web-$i" -o jsonpath='{.metadata.creationTimestamp}')
  [[ $(date -d "$created" +%s) -ge $(date -d "$ready" +%s) ]] || ok="no: web-$i created at $created, web-$((i - 1)) Ready at $ready"
done
assert_eq "each pod is started only when the previous one is ready" yes "$ok"
check_output "each pod knows its identity (its hostname)" '^web-1$' kubectl exec web-1 -- cat /data/me
# busybox nslookup ignores the search list and exits 1 on the AAAA query: full name, output only.
check_output "and finds the others through the headless service" "Name:[[:space:]]+web-2.web.$TEST_NS.svc.cluster.local" \
  bash -c "kubectl exec web-0 -- nslookup web-2.web.$TEST_NS.svc.cluster.local 2>&1 || true"
check_output "one PVC per pod: <claim-name>-<stateful-set-name>-<pod-index> (the correction)" \
  '^data-web-0 data-web-1 data-web-2$' \
  bash -c "kubectl get pvc -o jsonpath='{.items[*].metadata.name}' | xargs -n1 | sort | xargs"

section "Stopped in reverse order"
kubectl scale statefulset web --replicas=0 >/dev/null
# Record the pods still there, until none is left.
seen=
for _ in $(seq 1 240); do
  now=$(kubectl get pods -l app=web --field-selector=status.phase!=Succeeded -o jsonpath='{.items[*].metadata.name}' | xargs -n1 | sort | xargs)
  [[ $now != "${seen##*|}" ]] && seen="$seen|$now"
  [[ -z $now ]] && break
  sleep 0.5
done
assert_match "web-2 goes first, then web-1, then web-0" '\|web-0 web-1\|web-0\|$' "$seen"
check_output "the PVCs stay when the pods go" '^3$' bash -c 'kubectl get pvc --no-headers | wc -l'
