# shellcheck shell=bash
# The Docker volume that holds /nix for the nix env and the NixOS image builds, so
# nixpkgs and built systems are downloaded or built once, not on every run.

NIX_STORE_VOLUME=notes-nix-store
NIX_IMAGE=notes-test/nix:latest

# ensure_nix_store: build the nix image, and (re)create the volume from it. Docker
# fills an empty named volume from the image. A volume seeded by an older image
# lacks that image's own store paths, so it is replaced when the Dockerfile changes.
# The key is the Dockerfile's hash: the image ID changes on every build, even unchanged.
ensure_nix_store() {
  local root=${1:?repo root} id seeded lock
  docker build -q -t "$NIX_IMAGE" "$root/tests/envs/nix" >/dev/null
  id=$(sha256sum "$root/tests/envs/nix/Dockerfile" | cut -c1-16)
  # Two runs at once must not both recreate the volume: one would remove it under the other.
  mkdir -p "$root/.test-results"
  exec {lock}>"$root/.test-results/.nix-store.lock"
  flock "$lock"
  seeded=$(docker run --rm -v "$NIX_STORE_VOLUME:/nix" "$NIX_IMAGE" cat /nix/.seeded-from 2>/dev/null || true)
  if [[ $seeded == "$id" ]]; then
    exec {lock}>&-
    return 0
  fi
  if [[ -n $seeded ]]; then
    echo "nix image changed: recreating the $NIX_STORE_VOLUME volume" >&2
  fi
  docker volume rm -f "$NIX_STORE_VOLUME" >/dev/null
  docker run --rm -v "$NIX_STORE_VOLUME:/nix" "$NIX_IMAGE" sh -c "echo $id > /nix/.seeded-from"
  exec {lock}>&-
}

# in_nix CMD...: run CMD in the nix image, with the store volume and the repo at /repo.
in_nix() {
  docker run --rm -v "$NIX_STORE_VOLUME:/nix" -v "${NOTES_ROOT:?}:/repo:ro" -w /repo "$NIX_IMAGE" "$@"
}
