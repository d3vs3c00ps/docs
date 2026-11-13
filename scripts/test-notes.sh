#!/usr/bin/env bash
# Run the note tests in tests/. Each test declares, in its header, the note it checks
# and the environment it needs:
#
#   # note: linux/cli/tar.md
#   # env: leap              leap | rocky | nix | go         plain container
#                            priv:<env>                      same, with --privileged
#                            leap-systemd | rocky-systemd    systemd as PID 1
#                            nixos                           NixOS, systemd as PID 1
#                            kind | k3d                      runs on the host, against a
#                                                            shared test cluster
#                            compose                         runs on the host, with its
#                                                            own Docker Compose project
#   # nixos: server.nix      nixos only: a module next to the test, built into the system
#   # timeout: 600           optional, in seconds (default 600)
#
# Usage: scripts/test-notes.sh [-j N] [--env E] [--changed] [--delete-cluster] [PATH...]
#   PATH is a test, a note (content/x.md, x.md or x) or a folder. Default: all tests.
#   The kind/k3d cluster is kept between runs unless --delete-cluster is given.
#   CLUSTER=name picks another cluster, so two runs can test Kubernetes notes at once.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
# shellcheck source=../tests/versions.env
source tests/versions.env

RESULTS=$ROOT/.test-results
# Exported: tests name the cluster nodes (<cluster>-control-plane) through it.
export CLUSTER=${CLUSTER:-notes-test}
JOBS=1
ENV_FILTER=
CHANGED=0
KEEP_CLUSTER=1
PATHS=()

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while (($#)); do
  case $1 in
    -j) JOBS=$2; shift 2 ;;
    --env) ENV_FILTER=$2; shift 2 ;;
    --changed) CHANGED=1; shift ;;
    --delete-cluster) KEEP_CLUSTER=0; shift ;;
    -h | --help) usage ;;
    -*) echo "unknown option: $1" >&2; usage 1 ;;
    *) PATHS+=("$1"); shift ;;
  esac
done

# All test scripts: everything under tests/ except the harness itself.
all_tests() {
  find tests -name '*.sh' -not -path 'tests/lib/*' -not -path 'tests/envs/*' -not -path 'tests/k8s/*' | sort
}

# resolve PATH: print the test scripts it refers to.
resolve() {
  local p=${1%/}
  p=${p#./}
  p=${p#content/}
  p=${p#tests/}
  if [[ -d tests/$p ]]; then
    all_tests | grep "^tests/$p/" || true
  elif [[ -f tests/${p%.sh}.sh && $p == *.sh ]]; then
    echo "tests/${p%.sh}.sh"
  elif [[ -f tests/${p%.md}.sh ]]; then
    # A note: its test, and its extra tests (x.vm.sh).
    compgen -G "tests/${p%.md}.sh"
    compgen -G "tests/${p%.md}.*.sh" || true
  elif [[ -d content/$p || -f content/${p%.md}.md ]]; then
    : # a note or folder with no test yet: test-coverage.mjs reports that
  else
    echo "no test or note matches: $1" >&2
    return 1
  fi
}

# Changed files since the branch left main, plus uncommitted and untracked ones.
changed_tests() {
  local base files f
  base=$(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD main 2>/dev/null || echo HEAD)
  files=$( (git diff --name-only "$base"; git diff --name-only; git ls-files --others --exclude-standard) | sort -u)
  for f in $files; do
    case $f in
      tests/lib/* | tests/envs/* | tests/versions.env | scripts/test-notes.sh) all_tests; return ;;
      tests/k8s/*) all_tests | xargs grep -lE '^# env: (kind|k3d)$' || true ;;
      tests/nixos/* | scripts/nixos-image.sh)
        all_tests | xargs grep -lE '^# env: (priv:)?(nix|nixos)$' || true ;;
      tests/*.nix) grep -lx "# nixos: $(basename "$f")" "$(dirname "$f")"/*.sh 2>/dev/null ;;
      tests/*.sh) [[ -f $f ]] && echo "$f" ;;
      content/*.md)
        t=tests/${f#content/}
        compgen -G "${t%.md}.sh"
        compgen -G "${t%.md}.*.sh"
        ;;
    esac || true
  done
}

header() { sed -n "s/^# $2: *//p" "$1" | head -1; }

# --- select the tests -------------------------------------------------------------

if ((CHANGED)); then
  mapfile -t TESTS < <(changed_tests | sort -u)
elif ((${#PATHS[@]})); then
  found=
  for p in "${PATHS[@]}"; do
    found+=$(resolve "$p")$'\n'
  done
  mapfile -t TESTS < <(grep . <<<"$found" | sort -u || true)
else
  mapfile -t TESTS < <(all_tests)
fi

if [[ -n $ENV_FILTER ]]; then
  mapfile -t TESTS < <(for t in "${TESTS[@]}"; do
    e=$(header "$t" env)
    [[ $e == "$ENV_FILTER" || ${e#priv:} == "$ENV_FILTER" ]] && echo "$t"
  done)
fi

if ((${#TESTS[@]} == 0)); then
  echo "no tests selected"
  exit 0
fi

for t in "${TESTS[@]}"; do
  [[ -n $(header "$t" env) ]] || { echo "$t: missing '# env:' header" >&2; exit 1; }
  [[ -n $(header "$t" note) ]] || { echo "$t: missing '# note:' header" >&2; exit 1; }
done

mkdir -p "$RESULTS"

# --- environments -------------------------------------------------------------------

image_for() { echo "notes-test/${1#priv:}:latest"; }

# Every pinned version, as a build argument: an env Dockerfile declares the ARGs it uses.
VERSION_ARGS=()
while IFS='=' read -r key value; do
  VERSION_ARGS+=(--build-arg "$key=$value")
done < <(grep -E '^[A-Z_]+=' tests/versions.env)

# shellcheck source=../tests/lib/nix-store.sh
source tests/lib/nix-store.sh

# Build each needed image once, before any test starts. Docker's layer cache makes
# a rebuild with no changes take about a second.
build_images() {
  local env
  for env in $(printf '%s\n' "$@" | sed 's/^priv://' | sort -u); do
    # NixOS images are built per test, from the test's module, in run_one.
    if [[ $env == nix || $env == nixos ]]; then
      echo "preparing the $NIX_STORE_VOLUME volume" >&2
      ensure_nix_store "$ROOT"
      [[ $env == nix ]] && continue
    fi
    [[ $env == nixos ]] && continue
    [[ -f tests/envs/$env/Dockerfile ]] || { echo "unknown env: $env" >&2; exit 1; }
    echo "building image $(image_for "$env")" >&2
    docker build -q -t "$(image_for "$env")" "${VERSION_ARGS[@]}" "tests/envs/$env" >/dev/null
  done
}

kind_up() {
  # One kubeconfig per cluster: two runs with different CLUSTER values must not share one.
  export KUBECONFIG=$RESULTS/kubeconfig-kind-$CLUSTER
  if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    kind create cluster --name "$CLUSTER" --image "$KIND_NODE_IMAGE" \
      --config tests/k8s/kind.yaml --kubeconfig "$KUBECONFIG" --wait 180s
  else
    kind export kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG" >/dev/null
  fi
}

k3d_up() {
  export KUBECONFIG=$RESULTS/kubeconfig-k3d-$CLUSTER
  if ! k3d cluster list -o json 2>/dev/null | grep -q "\"name\": *\"$CLUSTER\""; then
    # Disk eviction off, as kind does, or a nearly full Docker disk taints every node.
    k3d cluster create "$CLUSTER" --image "$K3S_IMAGE" --agents 1 --wait \
      --k3s-arg '--kubelet-arg=eviction-hard=imagefs.available<1%,nodefs.available<1%@server:*;agent:*' \
      --kubeconfig-update-default=false --kubeconfig-switch-context=false
  fi
  k3d kubeconfig get "$CLUSTER" >"$KUBECONFIG"
}

# boot_and_run IMAGE TEST TIMEOUT LOG [ENV...]: start IMAGE with systemd as PID 1, wait
# for it to boot, run TEST inside it with the ENV variables. The container is removed after.
boot_and_run() {
  local image=$1 t=$2 timeout=$3 log=$4 cid status=0 e envs=()
  for e in "${@:5}"; do envs+=(-e "$e"); done
  cid=$(docker run -d --privileged --cgroupns=private --tmpfs /run --tmpfs /run/lock \
    -v "$ROOT:/repo:ro" -e container=docker "$image")
  # NixOS puts its commands on PATH only once /init has activated the system.
  for _ in $(seq 30); do docker exec "$cid" true >/dev/null 2>&1 && break; sleep 1; done
  # Poll: right after start, systemctl cannot reach systemd yet and fails at once.
  local state=
  for _ in $(seq 90); do
    state=$(docker exec "$cid" systemctl is-system-running 2>/dev/null || true)
    [[ $state == running || $state == degraded ]] && break
    sleep 1
  done
  if [[ $state != running && $state != degraded ]]; then
    echo "# systemd did not reach running state (last: ${state:-no answer})" >"$log"
    docker exec "$cid" systemctl --failed --no-pager >>"$log" 2>&1 || true
    status=1
  else
    # A login shell, so the test sees the session environment a user gets (NIX_PATH on NixOS).
    docker exec -e NOTES_ROOT=/repo "${envs[@]}" "$cid" timeout "$timeout" bash -l "/repo/$t" >"$log" 2>&1 || status=$?
  fi
  docker rm -fv "$cid" >/dev/null
  return "$status"
}

# run_one TEST: run a test in its environment, write its TAP log, return its status.
run_one() {
  local t=$1 env timeout log ns tmp module note image status=0
  env=$(header "$t" env)
  timeout=$(header "$t" timeout)
  timeout=${timeout:-600}
  log=$RESULTS/${t#tests/}
  log=${log%.sh}.tap
  mkdir -p "$(dirname "$log")"

  case $env in
    kind | k3d)
      # One namespace per test, so tests cannot see each other's objects.
      ns=t-$(basename "$t" .sh | tr -c 'a-z0-9\n' '-' | cut -c1-40)-$RANDOM
      kubectl create namespace "$ns" >/dev/null
      # A controller adds the default ServiceAccount a moment later; pods created before it are refused.
      kubectl -n "$ns" wait --for=create serviceaccount/default --timeout=60s >/dev/null
      # These tests run on this machine, so give each one a TMPDIR that is removed after it.
      # Under the repository, so a path a test mounts with `docker run -v` also exists on
      # the host when the test runs in the runner container.
      tmp=$(mktemp -d "$RESULTS/tmp.XXXXXX")
      TMPDIR=$tmp TEST_NS=$ns NOTES_ROOT=$ROOT timeout "$timeout" bash "$t" >"$log" 2>&1 || status=$?
      rm -rf "$tmp"
      kubectl delete namespace "$ns" --wait=false >/dev/null 2>&1 || true
      ;;
    compose)
      # A private project per test. Removed with its volumes, even when the test fails.
      ns=t-$(basename "$t" .sh | tr -c 'a-z0-9\n' '-' | cut -c1-40)-$RANDOM
      tmp=$(mktemp -d "$RESULTS/tmp.XXXXXX")
      (cd "$tmp" && TMPDIR=$tmp COMPOSE_PROJECT_NAME=$ns NOTES_ROOT=$ROOT timeout "$timeout" bash "$ROOT/$t") >"$log" 2>&1 || status=$?
      docker compose -p "$ns" down -v --remove-orphans >/dev/null 2>&1 || true
      rm -rf "$tmp"
      ;;
    *-systemd)
      boot_and_run "$(image_for "$env")" "$t" "$timeout" "$log" || status=$?
      ;;
    nixos)
      module=$(header "$t" nixos)
      module=${module:+$(dirname "$t")/$module}
      note=$(header "$t" note)
      note=${note%.md}
      if image=$(scripts/nixos-image.sh --note "$note" ${module:+"$module"} 2>"$log.build"); then
        boot_and_run "$image" "$t" "$timeout" "$log" "NIXOS_NOTE=$note" ${module:+"NIXOS_MODULE=/repo/$module"} || status=$?
      else
        { echo "# the NixOS image did not build"; sed 's/^/#   /' "$log.build"; } >"$log"
        status=1
      fi
      rm -f "$log.build"
      ;;
    *)
      local opts=()
      [[ $env == priv:* ]] && opts+=(--privileged)
      if [[ ${env#priv:} == nix ]]; then
        opts+=(-v "$NIX_STORE_VOLUME:/nix")
        # NixOS VM tests (tests/lib/nixos-vm.sh) need KVM, and skip without it.
        [[ -e /dev/kvm ]] && opts+=(--device /dev/kvm)
      fi
      docker run --rm "${opts[@]}" -v "$ROOT:/repo:ro" -e NOTES_ROOT=/repo \
        "$(image_for "$env")" timeout "$timeout" bash "/repo/$t" >"$log" 2>&1 || status=$?
      ;;
  esac

  local pass fail skipped
  pass=$(grep -c '^ok ' "$log" || true)
  fail=$(grep -c '^not ok ' "$log" || true)
  skipped=$(grep -c '^ok .* # SKIP' "$log" || true)
  if ((status == 0)); then
    printf 'PASS  %-55s %3d ok %3d skip\n' "${t#tests/}" "$((pass - skipped))" "$skipped"
  else
    printf 'FAIL  %-55s %3d ok %3d fail  (exit %d, log: %s)\n' "${t#tests/}" "$((pass - skipped))" "$fail" "$status" "${log#"$ROOT"/}"
  fi
  return "$status"
}

# --- run ----------------------------------------------------------------------------

CONTAINER_TESTS=()
CONTAINER_ENVS=()
KIND_TESTS=()
K3D_TESTS=()
COMPOSE_TESTS=()
for t in "${TESTS[@]}"; do
  case $(header "$t" env) in
    kind) KIND_TESTS+=("$t") ;;
    compose) COMPOSE_TESTS+=("$t") ;;
    k3d) K3D_TESTS+=("$t") ;;
    *) CONTAINER_TESTS+=("$t"); CONTAINER_ENVS+=("$(header "$t" env)") ;;
  esac
done
((${#CONTAINER_ENVS[@]} == 0)) || build_images "${CONTAINER_ENVS[@]}"

FAILED=()
# One summary per run: two runs at once must not mix their results.
SUMMARY=$(mktemp "$RESULTS/summary.XXXXXX")
trap 'rm -f "$SUMMARY"' EXIT

# Container tests run in parallel with -j. Cluster tests stay sequential: some of them
# touch cluster-wide objects.
running=0
for t in "${CONTAINER_TESTS[@]}"; do
  (run_one "$t" >>"$SUMMARY") &
  running=$((running + 1))
  if ((running >= JOBS)); then
    wait -n || true
    running=$((running - 1))
  fi
done
wait || true

# One at a time, also across runs: notes publish fixed ports (9090, 3000...) on localhost.
if ((${#COMPOSE_TESTS[@]})); then
  exec 9>"$RESULTS/.compose.lock"
  flock 9
  for t in "${COMPOSE_TESTS[@]}"; do run_one "$t" >>"$SUMMARY" || true; done
  flock -u 9
fi

if ((${#KIND_TESTS[@]})); then
  kind_up
  for t in "${KIND_TESTS[@]}"; do run_one "$t" >>"$SUMMARY" || true; done
  ((KEEP_CLUSTER)) || kind delete cluster --name "$CLUSTER"
fi

if ((${#K3D_TESTS[@]})); then
  k3d_up
  for t in "${K3D_TESTS[@]}"; do run_one "$t" >>"$SUMMARY" || true; done
  ((KEEP_CLUSTER)) || k3d cluster delete "$CLUSTER"
fi

sort -k2 "$SUMMARY"
mapfile -t FAILED < <(grep '^FAIL' "$SUMMARY" || true)
total=$(wc -l <"$SUMMARY")
echo
echo "$((total - ${#FAILED[@]})) of $total test files passed. Logs in ${RESULTS#"$ROOT"/}/"
((${#FAILED[@]} == 0))
