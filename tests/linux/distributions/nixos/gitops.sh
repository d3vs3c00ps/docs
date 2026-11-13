#!/usr/bin/env bash
# note: linux/distributions/nixos/gitops.md
# env: nixos
# timeout: 2400
# The note's repository is built in a temporary directory: its flake.nix, with small
# hosts and modules. nixpkgs is the pinned one; sops-nix and deploy-rs come from
# GitHub. Nothing is deployed: there are no remote hosts.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/nixos.sh"

NOTE=linux/distributions/nixos/gitops
NIXPKGS=$(nix eval --impure --raw --expr '(builtins.getFlake "path:/repo/tests/nixos").inputs.nixpkgs.outPath')
P=path:$NIXPKGS
nb() { note_block "$NOTE" "$@"; }
cd "$(mktemp -d)"
R=$PWD/nixos-config

section "Repository layout"
mkdir -p "$R"/hosts/{web-01,web-02,db-01} "$R"/modules/services "$R"/secrets "$R"/home "$R"/overlays
for h in web-01 web-02 db-01; do
  cat >"$R/hosts/$h/default.nix" <<NIX
_: {
  networking.hostName = "$h";
  boot.loader.grub.device = "nodev";
  fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
  system.stateVersion = "26.05";
}
NIX
done
echo '_: { services.openssh.enable = true; }' >"$R/modules/common.nix"
echo '_: { security.sudo.execWheelOnly = true; }' >"$R/modules/hardening.nix"
nb 'Repository layout' 2 >"$R/flake.nix"
cd "$R"
check "nix flake lock, nixpkgs pinned (sops-nix and deploy-rs from GitHub)" \
  nix flake lock --override-input nixpkgs "$P" \
  --override-input sops-nix/nixpkgs "$P" --override-input deploy-rs/nixpkgs "$P"
ev() { nix eval --raw "path:$R#$1"; }
check_output "web-01 evaluates to a system derivation" '\.drv$' ev nixosConfigurations.web-01.config.system.build.toplevel.drvPath
check_output "mkHost adds the common module" '^1$' nix eval "path:$R#nixosConfigurations.db-01.config.services.openssh.enable" --apply 'x: if x then 1 else 0'
check_output "and the hardening module" '^true$' nix eval "path:$R#nixosConfigurations.web-02.config.security.sudo.execWheelOnly"
check_output "and the sops-nix module" '^true$' nix eval "path:$R#nixosConfigurations.web-01.options" --apply 'o: o ? sops'
check_output "the deploy node points at web-01.example.com" '^web-01\.example\.com$' ev deploy.nodes.web-01.hostname
check_output "its profile is deploy-rs's activation wrapper for web-01" 'activatable-nixos-system-web-01' \
  ev deploy.nodes.web-01.profiles.system.path.name
check "nix flake check --no-build" nix flake check --no-build "path:$R"

section "CI"
yq() { nix run "$P#yq-go" -- "$@"; }
nb CI 1 >ci.yaml
check_output "the build workflow is valid YAML with a host matrix" '^\["web-01","web-02","db-01"\]$' \
  yq -o json -I 0 '.jobs.build.strategy.matrix.host' ci.yaml
build=$(nb CI 1 | sed -n 's/.*- run: \(nix build .*\)/\1/p' | sed 's/\${{ matrix.host }}/web-01/')
check_output "the build step's attribute exists (evaluated, not built: an x86_64 system)" '\.drv$' \
  nix eval --raw "path:$R#nixosConfigurations.web-01.config.system.build.toplevel.drvPath"
assert_match "the build step builds the toplevel" '^nix build \.#nixosConfigurations\.web-01\.config\.system\.build\.toplevel$' "$build"
extra=$(nb CI 2 | sed -n 's/^ *- run: //p')
vh=$(nix run "$P#vulnix" -- --help 2>/dev/null)
assert_match "vulnix --system scans the machine it runs on (the correction)" '\-S, --system +Scan the current system' "$vh"
assert_match "--closure scans what a path depends on" '\-C, --closure +Examine the closure of an output path' "$vh"
nixcmd=$(grep nixfmt <<<"$extra" | sed "s|nixpkgs#|$P#|; s|\$(git ls-files '\*.nix')|\$(find . -name '*.nix')|")
(cd "$R" && find . -name '*.nix' -exec nix run "$P#nixfmt" -- {} + 2>/dev/null) || true
check "nixfmt --check on the repository's files, once formatted (from the note)" bash -c "cd $R && $nixcmd"
check "statix check runs on the repository (from the note)" bash -c "cd $R && $(grep statix <<<"$extra" | sed "s|nixpkgs#|$P#|")"
check "deadnix --fail runs on the repository (from the note)" bash -c "cd $R && $(grep deadnix <<<"$extra" | sed "s|nixpkgs#|$P#|")"

section "A binary cache"
check_output "the substituters block evaluates" 'myorg\.cachix\.org' nixos_eval --host --block 'A binary cache' 1 nix.settings.substituters
check_output "the cache.nixos.org key is the real one" 'cache\.nixos\.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=' \
  grep -h 'cache.nixos.org-1' /etc/nix/nix.conf

section "Deployment"
dhelp=$(nix run "$P#deploy-rs" -- --help 2>&1)
assert_match "deploy takes one target, and --targets for several" '\[TARGET\].*--targets <TARGETS>' "$(tr '\n' ' ' <<<"$dhelp")"
readme=$(nix eval --raw --impure --expr "(builtins.getFlake \"path:$R\").inputs.deploy-rs.outPath")/README.md
check_output "magicRollback is on by default (deploy-rs README)" 'magicRollback.*true|true.*magicRollback' grep -i 'magicRollback' "$readme"
check_output "the magicRollback block evaluates in deploy.nodes" '^30$' nix eval --impure --expr \
  "let f = builtins.getFlake \"path:$R\"; in (f.deploy.nodes.web-01.profiles.system // ($(nb Deployment 2 | sed -n '/= {/,/};/p' | sed '1s/.*= {/{/; $s/};/}/'))).confirmTimeout"

section "Pull-based updates"
check_output "autoUpgrade evaluates to a timer at 04:00" '04:00' nixos_eval --host --block 'Pull-based updates' 1 systemd.timers.nixos-upgrade.timerConfig.OnCalendar
check_output "with a randomized delay" '45min' nixos_eval --host --block 'Pull-based updates' 1 systemd.timers.nixos-upgrade.timerConfig.RandomizedDelaySec

section "Updating dependencies"
check "nix flake update with one input name (from the note, on sops-nix)" bash -c "cd $R && $(nb 'Updating dependencies' 1 | sed -n 2p | sed 's/#.*//; s/nixpkgs/sops-nix/') --override-input nixpkgs $P --override-input deploy-rs/nixpkgs $P --override-input sops-nix/nixpkgs $P"

# The staged pipeline is a fragment of the jobs: map, so it gets a jobs: key here.
nb CI 1 >wf-ci.yaml
{ echo 'jobs:'; nb Deployment 3; } >wf-deploy.yaml
nb 'Updating dependencies' 2 >wf-update.yaml
for wf in ci deploy update; do
  check_output "every job in the $wf workflow has runs-on" '^true$' yq '[.jobs | to_entries[] | .value | has("runs-on")] | all' "wf-$wf.yaml"
done

section "Secrets"
nix shell "$P#openssh" --command ssh-keygen -q -t ed25519 -N '' -f hostkey
cmd=$(nb Secrets 2 | sed -n 1p | sed "s|ssh-keyscan -t ed25519 web-01.example.com|cat hostkey.pub|; s|nixpkgs#|$P#|")
age=$(bash -c "$cmd" 2>/dev/null)
check_output "ssh-to-age turns the host key into an age recipient (from the note)" '^age1[a-z0-9]{58}$' echo "$age"
check_output "the original pipe fails: ssh-to-age is not on PATH outside nix shell" 'ssh-to-age: command not found' \
  bash -c "nix shell $P#coreutils --command cat hostkey.pub | ssh-to-age 2>&1; true"
mkdir -p secrets
nb Secrets 1 | sed "s/age1xxxxx\.\.\./$age/" >.sops.yaml
echo 'db_password: hunter2' >secrets/web-01.yaml
check "sops encrypts secrets/web-01.yaml with the .sops.yaml rule" nix run "$P#sops" -- --encrypt --in-place secrets/web-01.yaml
check_output "the file now holds only ciphertext and the recipient" "recipient: $age" cat secrets/web-01.yaml
check_fails "and no clear password" grep -q hunter2 secrets/web-01.yaml
