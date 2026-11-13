# shellcheck shell=bash
# Helpers for tests with `# env: nixos`. The test runs inside the booted NixOS system.
# The runner sets NIXOS_NOTE and NIXOS_MODULE (the `# nixos:` module, if any).
#
#   nixos_eval [--host] [--block HEADING N] ATTR
#       print config.ATTR as JSON. By default, of the system the test runs in.
#       --block: of a system made of that one code block of the note instead.
#       --host:  evaluated as a normal machine, without the Docker profile. Use it for
#                what the container turns off or must never apply: kernel, audit.
#       Fails, with Nix's error on stderr, when the configuration does not evaluate.

nixos_eval() {
  local container=true module=null attr
  [[ -n ${NIXOS_MODULE:-} ]] && module=$NIXOS_MODULE
  while (($#)); do
    case $1 in
      --host) container=false; shift ;;
      --block) module="{ notes, ... }: { imports = [ (notes.module \"$2\" $3) ]; }"; shift 3 ;;
      *) break ;;
    esac
  done
  attr=${1:?nixos_eval: which attribute?}
  nix eval --impure --json --expr "((builtins.getFlake \"path:/repo/tests/nixos\").lib.system {
      module = $module; note = \"${NIXOS_NOTE:?}\"; container = $container;
    }).config.$attr"
}
