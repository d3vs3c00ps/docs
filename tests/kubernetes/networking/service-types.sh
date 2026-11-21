#!/usr/bin/env bash
# note: kubernetes/networking/service-types.md
# env: kind
# timeout: 1200
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/networking/service-types
use_test_namespace

section "Services and endpoints"
check "the note's lab: deployment blue with a service" \
  bash -ec "$(note_block "$NOTE" 'Services and endpoints' 1)"
kubectl rollout status deployment/blue --timeout=180s >/dev/null
check_output "describe lists one endpoint per ready pod" 'Endpoints:.*:80' \
  kubectl describe service blue
eps=$(kubectl get endpointslices -l kubernetes.io/service-name=blue \
  -o jsonpath='{.items[*].endpoints[*].addresses[0]}' | tr ' ' '\n' | sort)
pods=$(kubectl get pods -l app=blue -o jsonpath='{.items[*].status.podIP}' | tr ' ' '\n' | sort)
assert_eq "the endpoint addresses match the pod addresses" "$pods" "$eps"
check_output "the EndpointSlice command from the note works" 'blue' \
  kubectl get endpointslices -l kubernetes.io/service-name=blue
check_output "Endpoints is deprecated since 1.33, as the callout says" 'deprecated' \
  bash -c 'kubectl get endpoints blue 2>&1 >/dev/null'
check_output "'endpoint' cannot be singular" "doesn't have a resource type \"endpoint\"" \
  bash -c 'kubectl get endpoint 2>&1; true'

section "ClusterIP"
ip=$(kubectl get service blue -o jsonpath='{.spec.clusterIP}')
assert_eq "ClusterIP is the default type" ClusterIP "$(kubectl get service blue -o jsonpath='{.spec.type}')"
check_output "the virtual IP is in an internal private range" '^10\.' echo "$ip"
check_output "it is reachable from inside the cluster, on the original port" 'blue' \
  kubectl run cip-probe --image=alpine --restart=Never --rm -i --quiet -- \
  wget -qO- -T 10 "http://$ip:80"

section "NodePort"
kubectl expose deployment blue --name=blue-np --type=NodePort --port=80 >/dev/null
np=$(kubectl get service blue-np -o jsonpath='{.spec.ports[0].nodePort}')
check "the allocated port is in the default 30000-32767 range" \
  bash -c "[ $np -ge 30000 ] && [ $np -le 32767 ]"
node_ip=$(kubectl get nodes "$CLUSTER-worker" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
check_output "the port answers on a node address" 'blue' \
  bash -c "curl -fs --retry 10 --retry-all-errors http://$node_ip:$np"

section "ExternalName"
check "kubectl create service externalname (from the note)" \
  bash -ec "$(note_block "$NOTE" 'ExternalName' 1)"
assert_eq "it is only a DNS alias: a CNAME to the provided record" "kubernetes.io" \
  "$(kubectl get service k8s -o jsonpath='{.spec.externalName}')"
check_output "CoreDNS answers with the CNAME" 'kubernetes.io' retry_out 5 bash -c \
  "kubectl delete pod dns-probe --ignore-not-found --wait >/dev/null 2>&1; kubectl run dns-probe --image=alpine --restart=Never --rm -i --quiet -- \
  nslookup k8s.$TEST_NS.svc.cluster.local | grep kubernetes.io"

section "External IPs"
kubectl create deployment my-little-deploy --image=jpetazzo/color >/dev/null
check "the note's expose command with --external-ip" \
  bash -ec "$(note_block "$NOTE" 'External IPs' 1)"
assert_eq "the address lands in spec.externalIPs" "1.2.3.4" \
  "$(kubectl get service my-little-deploy -o jsonpath='{.spec.externalIPs[0]}')"

section "Headless services"
kubectl expose deployment blue --name=blue-headless --port=80 --cluster-ip=None >/dev/null
kubectl rollout status deployment/blue --timeout=180s >/dev/null
assert_eq "clusterIP None means no virtual IP" "None" \
  "$(kubectl get service blue-headless -o jsonpath='{.spec.clusterIP}')"
# The claim is one A record per ready pod: compare with the pod count, and show the answer.
# kubectl run --rm -i can attach before the container exists: try again.
ready=$(kubectl get deployment blue -o jsonpath='{.status.readyReplicas}')
check_output "CoreDNS returns one A record per pod ($ready pods)" "^records=$ready\$" retry_out 20 bash -c \
  "kubectl delete pod headless-probe --ignore-not-found --wait >/dev/null 2>&1
   out=\$(kubectl run headless-probe --image=alpine --restart=Never --rm -i --quiet -- \
     nslookup blue-headless.$TEST_NS.svc.cluster.local 2>&1)
   n=\$(grep -c '^Address: 10\.' <<<\"\$out\")
   [ \"\$n\" = $ready ] && echo records=\$n || { echo \"records=\$n\"; echo \"\$out\"; exit 1; }"

section "Traffic engineering: Local is a hard rule"
# one backend, pinned to worker; Local via worker2 must fail, via worker must work
kubectl create deployment pinned --image=jpetazzo/color >/dev/null
kubectl patch deployment pinned -p \
  "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"$CLUSTER-worker\"}}}}}" >/dev/null
kubectl rollout status deployment/pinned --timeout=180s >/dev/null
kubectl expose deployment pinned --name=pinned-np --type=NodePort --port=80 >/dev/null
kubectl patch service pinned-np -p '{"spec":{"externalTrafficPolicy":"Local"}}' >/dev/null
pnp=$(kubectl get service pinned-np -o jsonpath='{.spec.ports[0].nodePort}')
w1=$(kubectl get nodes "$CLUSTER-worker" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
w2=$(kubectl get nodes "$CLUSTER-worker2" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
check_output "via the node with the backend, Local works" 'pinned' \
  bash -c "curl -fs --retry 10 --retry-all-errors http://$w1:$pnp"
# kube-proxy on the other node applies the Local policy a moment after the patch.
check "via a node without a backend, the connection fails (hard rule)" \
  retry 30 bash -c "! curl -fs -m 5 http://$w2:$pnp >/dev/null"

section "spec.trafficDistribution"
check "PreferClose is accepted (stable since 1.33)" \
  kubectl patch service blue -p '{"spec":{"trafficDistribution":"PreferClose"}}'
check "PreferSameNode is accepted (beta since 1.34)" \
  kubectl patch service blue -p '{"spec":{"trafficDistribution":"PreferSameNode"}}'
