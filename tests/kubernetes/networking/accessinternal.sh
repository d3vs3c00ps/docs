#!/usr/bin/env bash
# note: kubernetes/networking/accessinternal.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/networking/accessinternal
use_test_namespace

kubectl create deployment webui --image=nginx:1.29 >/dev/null
kubectl expose deployment webui --port=80 >/dev/null
kubectl create deployment redis --image=redis:7-alpine >/dev/null
kubectl expose deployment redis --port=6379 >/dev/null
kubectl rollout status deployment/webui --timeout=180s >/dev/null
kubectl rollout status deployment/redis --timeout=180s >/dev/null

section "kubectl proxy"
# The note's lab targets namespace "default"; here the service lives in the test namespace.
block=$(note_block "$NOTE" 'kubectl proxy' 2 | sed "s/namespaces\/default/namespaces\/$TEST_NS/" \
  | sed '/kubectl proxy &/a sleep 3')
check_output "the note's proxy lab reaches the webui service over the API" 'Welcome to nginx!' \
  bash -ec "$block"
check_fails "once killed, the proxy port no longer answers" \
  curl -fs -m 3 "localhost:8001/api/v1/namespaces/$TEST_NS/services/webui/proxy/index.html"

section "kubectl port-forward"
block=$(note_block "$NOTE" 'kubectl port-forward' 2 | \
  sed 's|redis-cli -p 10000|docker run --rm --network host redis:7-alpine redis-cli -p 10000|' \
  | sed '/port-forward/a sleep 3')
check_output "the note's port-forward lab talks to Redis" 'redis_version' \
  bash -ec "$block"
check_fails "once killed, the forwarded port no longer answers" \
  docker run --rm --network host redis:7-alpine redis-cli -p 10000 -t 3 PING
