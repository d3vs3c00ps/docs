#!/usr/bin/env bash
# note: containers/concepts.md
# env: compose
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"

P=$COMPOSE_PROJECT_NAME
cleanup() { docker rm -f "$P-ns" "$P-ns2" >/dev/null 2>&1; docker rmi -f "$P-whiteout" >/dev/null 2>&1 || true; }
trap 'cleanup; _t_finish $?' EXIT

section "1. Namespaces: container processes are host processes"
docker run -d --name "$P-ns" busybox:1.37 sleep 300 >/dev/null
check_output "the container process is visible from the host (docker top)" 'sleep 300' \
  docker top "$P-ns"
PID=$(docker inspect -f '{{.State.Pid}}' "$P-ns")
check "docker inspect .State.Pid gives its host PID (from the note's callout)" test "$PID" -gt 0

section "5. The filesystem — layers and copy-on-write"
if docker inspect -f '{{ .GraphDriver.Driver }}' "$P-ns" >/dev/null 2>&1 && \
   [[ -n $(docker inspect -f '{{ .GraphDriver.Data.UpperDir }}' "$P-ns" 2>/dev/null) ]]; then
  check_output "docker inspect UpperDir (from the note)" '/' \
    docker inspect -f '{{ .GraphDriver.Data.UpperDir }}' "$P-ns"
  docker run -d --name "$P-ns2" busybox:1.37 sleep 300 >/dev/null
  l1=$(docker inspect -f '{{ .GraphDriver.Data.LowerDir }}' "$P-ns")
  l2=$(docker inspect -f '{{ .GraphDriver.Data.LowerDir }}' "$P-ns2")
  assert_eq "two containers from one image share the read-only layers" "$l1" "$l2"
else
  skip "docker inspect UpperDir / LowerDir" \
    "containerd image store: no GraphDriver, as the note's callout says"
fi

docker exec "$P-ns" sh -c 'echo scratch > /ephemeral'
docker rm -f "$P-ns" >/dev/null
check "writes to the container layer die with the container" \
  docker run --rm busybox:1.37 sh -c '! test -e /ephemeral'

# "a secret RUN-ed in and rm-ed out is still recoverable": the earlier layer keeps it.
mkdir -p build && cat >build/Dockerfile <<'EOF'
FROM busybox:1.37
RUN echo "s3cret" > /secret.txt
RUN rm /secret.txt
EOF
docker build -q -t "$P-whiteout" build >/dev/null
check "the final image does not show the deleted file" \
  docker run --rm "$P-whiteout" sh -c '! test -e /secret.txt'
docker save "$P-whiteout" -o layers.tar && mkdir -p layers && tar -xf layers.tar -C layers
# docker save writes OCI layout: layers are extension-less blobs under blobs/sha256.
check "the secret is still in an earlier layer of the saved image" \
  bash -c "find layers -type f | while read -r f; do tar -tf \"\$f\" 2>/dev/null; done | grep -q secret.txt"
