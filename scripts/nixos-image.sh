#!/usr/bin/env bash
# Build a NixOS system and import it into Docker. Prints the image name.
#
# Usage: scripts/nixos-image.sh [--note NOTE] [MODULE]
#   MODULE is a .nix file in this repository, added to tests/nixos/base.nix.
#   With no MODULE, the base system alone.
#   NOTE (e.g. linux/distributions/nixos/hardening) lets MODULE use that note's code
#   blocks: `{ notes, ... }: { imports = [ (notes.module "Heading" 1) ]; }`
#
# The build runs in the nix image with the notes-nix-store volume, so no Nix is needed
# on this machine. The image is named after the store path of the system, so the same
# configuration is imported once, and a changed one gets a new image.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
export NOTES_ROOT=$ROOT
# shellcheck source=../tests/lib/nix-store.sh
source "$ROOT/tests/lib/nix-store.sh"

note=null
if [[ ${1:-} == --note ]]; then
  n=${2:?--note needs a note path}
  n=${n#content/}
  n=${n%.md}
  [[ -f $ROOT/content/$n.md ]] || { echo "no such note: $2" >&2; exit 1; }
  note="\"$n\""
  shift 2
fi
module=${1:-}
arg=null
if [[ -n $module ]]; then
  module=$(realpath --relative-to="$ROOT" "$module")
  [[ -f $ROOT/$module && $module != ../* ]] || { echo "not a file in this repo: $1" >&2; exit 1; }
  arg="/repo/$module"
fi

ensure_nix_store "$ROOT"
out=$(in_nix nix build --impure --no-link --print-out-paths --quiet --expr \
  "(builtins.getFlake \"path:/repo/tests/nixos\").lib.tarball { module = $arg; note = $note; }")

# /run/current-system appears only when the system activates at boot. The profile
# path works before that, for the first docker exec.
# Each image is 2-3 GB. The key label says which test it is for, so an older image for
# the same test is removed when a changed configuration is imported.
key=$(echo "$note $module" | sha256sum | cut -c1-12)
changes=(
  --change 'CMD ["/init"]'
  --change 'ENV PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/system/sw/bin'
  --change "LABEL notes-test.nixos=$key"
)
image=notes-test/nixos:$(echo "$out ${changes[*]}" | sha256sum | cut -c1-12)
if ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "importing $image" >&2
  in_nix sh -c "cat $out/tarball/*.tar.xz" | docker import "${changes[@]}" - "$image" >/dev/null
  # Docker has it now. The system closure stays in the store, so a rebuild is quick.
  in_nix nix-store --delete "$out" >/dev/null 2>&1 || true
  docker images --filter "label=notes-test.nixos=$key" --format '{{.Repository}}:{{.Tag}}' |
    grep -vx "$image" | xargs -r docker rmi >/dev/null 2>&1 || true
fi
echo "$image"
