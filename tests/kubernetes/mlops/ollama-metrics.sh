#!/usr/bin/env bash
# note: kubernetes/mlops/ollama-metrics.md
# env: kind
# timeout: 1200
# The Helm commands are checked with helm template (metrics-server and kube-prometheus-stack
# are tested in their own notes). The HAProxy sidecar runs for real, in front of a stand-in backend.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"
use_test_namespace

NOTE=kubernetes/mlops/ollama-metrics
cd "$(mktemp -d)"
# template BLOCK: the note's helm upgrade --install, as helm template.
template() { bash -ec "$(sed 's/helm upgrade --install/helm template/; s/--create-namespace//' <<<"$1")" 2>&1; }

section "Installing metrics-server"
check_output "--set args={--kubelet-insecure-tls=true} reaches the container (from the note)" '^ +- --kubelet-insecure-tls=true$' \
  template "$(note_block "$NOTE" 2)"

section "Installing kube-prometheus-stack"
assert_match "the note pins the tested chart" "--version $KUBE_PROMETHEUS_STACK_CHART" "$(note_block "$NOTE" 3)"
template "$(note_block "$NOTE" 3)" >kps.yaml
# doc KIND NAME: one YAML document of the rendered chart.
doc() { awk -v k="kind: $1" -v n="  name: $2" '/^---/{if(hit)exit; buf=""; kk=0; nn=0; next} {buf=buf $0 "\n"} $0==k{kk=1} $0==n{nn=1} kk&&nn{hit=1} END{if(hit)printf "%s", buf}' kps.yaml; }
check_output "Grafana gets a NodePort Service (from the note)" '^  type: "?NodePort"?$' doc Service promstack-grafana
check_output "Prometheus gets a NodePort Service (from the note)" '^  type: "?NodePort"?$' doc Service promstack-kube-prometheus-prometheus
check_output "...NilUsesHelmValues=false: Prometheus selects all ServiceMonitors (from the note)" '^  serviceMonitorSelector: \{\}$' doc Prometheus promstack-kube-prometheus-prometheus
check_output "...and all PodMonitors (from the note)" '^  podMonitorSelector: \{\}$' doc Prometheus promstack-kube-prometheus-prometheus
pw=$(doc Secret promstack-grafana | sed -n 's/^  admin-password: "\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' | base64 -d)
check_output "the Grafana password is random, not prom-operator (the correction)" '^[A-Za-z0-9]{20,}$' echo "$pw"
assert_match "the note reads it from the promstack-grafana Secret" 'secret promstack-grafana' "$(note_block "$NOTE" 6)"

section "HAProxy to the rescue"
kubectl create configmap haproxy --from-file=haproxy.cfg=/dev/stdin >/dev/null <<<"$(note_block "$NOTE" 7)"
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: ollama, labels: {app: ollama}}
spec:
  containers:
  - name: ollama
    image: busybox:1.37
    command: [sh, -c, 'mkdir /www && echo fake-ollama >/www/index.html && httpd -f -p 11434 -h /www']
  - name: haproxy
    image: haproxy:$HAPROXY_VERSION
    volumeMounts: [{name: cfg, mountPath: /usr/local/etc/haproxy}]
  volumes: [{name: cfg, configMap: {name: haproxy}}]
EOF
check "the sample configuration is valid for HAProxy (from the note)" bash -c \
  "kubectl wait --for=condition=Ready pod/ollama --timeout=180s >/dev/null && kubectl exec ollama -c haproxy -- haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg"
check_output "port 8000 proxies to Ollama on localhost:11434 (from the note)" '^fake-ollama$' \
  kubectl exec ollama -c ollama -- wget -qO- localhost:8000/
check_output "port 9000 exposes Prometheus metrics (from the note)" 'haproxy_frontend_current_sessions\{proxy="ollama_frontend"\}' \
  kubectl exec ollama -c ollama -- wget -qO- localhost:9000/metrics
check_output "with the request counters per backend" 'haproxy_backend_http_responses_total\{proxy="ollama_backend",code="2xx"\} [1-9]' \
  kubectl exec ollama -c ollama -- wget -qO- localhost:9000/metrics
check_output "maxconn 16 on the frontend (from the note)" 'haproxy_frontend_limit_sessions\{proxy="ollama_frontend"\} 16' \
  kubectl exec ollama -c ollama -- wget -qO- localhost:9000/metrics
kubectl delete pod ollama --wait=false >/dev/null

section "Request duration: Ollama still has no metrics"
kubectl run real-ollama --image="ollama/ollama:$OLLAMA_VERSION" >/dev/null
kubectl wait --for=condition=Ready pod/real-ollama --timeout=900s >/dev/null
check_output "GET /metrics on Ollama is a 404 (from the note)" '^404$' bash -c \
  "kubectl exec real-ollama -- bash -c 'exec 3<>/dev/tcp/127.0.0.1/11434; printf \"GET /metrics HTTP/1.0\r\n\r\n\" >&3; head -1 <&3' | awk '{print \$2}'"
