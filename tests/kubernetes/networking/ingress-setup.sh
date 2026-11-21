#!/usr/bin/env bash
# note: kubernetes/networking/ingress-setup.md
# env: kind
# timeout: 1800
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/networking/ingress-setup
use_test_namespace
cleanup() {
  helm uninstall traefik --namespace traefik >/dev/null 2>&1
  kubectl delete namespace traefik --ignore-not-found --timeout=120s >/dev/null 2>&1
  # helm leaves its CRDs behind; drop the Gateway API ones so the next test's
  # cloud-provider-kind can re-apply them without an ownership conflict.
  kubectl get crd -o name 2>/dev/null | grep 'gateway.networking.k8s.io' \
    | xargs -r kubectl delete >/dev/null 2>&1
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT

section "Installing Traefik with a LoadBalancer"
# cloud-provider-kind and the Traefik chart both apply the Gateway API CRDs, and
# server-side apply refuses the second owner. Install Traefik first, cpk after.
kubectl delete crd backendtlspolicies.gateway.networking.k8s.io gatewayclasses.gateway.networking.k8s.io \
  gateways.gateway.networking.k8s.io grpcroutes.gateway.networking.k8s.io \
  httproutes.gateway.networking.k8s.io referencegrants.gateway.networking.k8s.io \
  --ignore-not-found >/dev/null 2>&1 || true
LBSEC='Installing Traefik with a `LoadBalancer`'
check "the note's helm install" bash -ec "$(note_block "$NOTE" "$LBSEC" 1)"
start_cloud_provider_kind
check "the scripted wait from the note" bash -ec "$(note_block "$NOTE" "$LBSEC" 3 | sed -n 1,2p)"
LB_IP=$(bash -ec "$(note_block "$NOTE" "$LBSEC" 3 | sed -n 3,4p)")
check "the note's jsonpath extracts the external IP" test -n "$LB_IP"
check_output "a request to the external IP gets Traefik's 404" '404' \
  curl -s --retry 15 --retry-all-errors -o /dev/null -w '%{http_code}' "http://$LB_IP"

section "Installing Traefik with a DaemonSet + hostPort"
DSSEC='Installing Traefik with a `DaemonSet`'
check "the note's helm upgrade with the DaemonSet options" \
  bash -ec "$(note_block "$NOTE" "$DSSEC" 1)"
kubectl -n traefik rollout status daemonset/traefik --timeout=300s >/dev/null
assert_eq "the chart switched to a DaemonSet" "daemonset" \
  "$(kubectl -n traefik get daemonset traefik -o jsonpath='{.kind}' | tr '[:upper:]' '[:lower:]')"
assert_eq "the Service is now ClusterIP" "ClusterIP" \
  "$(kubectl -n traefik get service traefik -o jsonpath='{.spec.type}')"
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[?(@.metadata.name=="'"$CLUSTER"'-worker")].status.addresses[?(@.type=="InternalIP")].address}')
check_output "any node answers on port 80 with Traefik's 404" '404' \
  curl -s --retry 15 --retry-all-errors -o /dev/null -w '%{http_code}' "http://$NODE_IP"
check_output "the control plane node does not run Traefik (taint, no toleration)" '^0$' \
  bash -c "kubectl -n traefik get pods -o wide --no-headers | grep -c control-plane; true"

section "What about local dev clusters?"
check_output "port-forward to the service answers Traefik's 404" '404' bash -c "
  kubectl port-forward --namespace=traefik service/traefik 8888:80 >/dev/null 2>&1 &
  pf=\$!; sleep 3
  code=\$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8888)
  kill \$pf 2>/dev/null; echo \$code"

section "The Traefik dashboard"
check "redeploy with the dashboard IngressRoute enabled" bash -ec "
  $(note_block "$NOTE" "$DSSEC" 1) --set ingressRoute.dashboard.enabled=true"
kubectl -n traefik rollout status daemonset/traefik --timeout=300s >/dev/null
check_output "the dashboard answers on the internal entrypoint (trailing slash)" \
  '<title>Traefik' bash -c "
  kubectl port-forward --namespace=traefik daemonset/traefik 1234:8080 >/dev/null 2>&1 &
  pf=\$!; sleep 3
  curl -s --retry 10 --retry-all-errors http://localhost:1234/dashboard/
  kill \$pf 2>/dev/null"
