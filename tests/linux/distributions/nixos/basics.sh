#!/usr/bin/env bash
# note: linux/distributions/nixos/basics.md
# env: nixos
# timeout: 2400
# The container plays a machine just after install: /etc/nixos gets the note's flake
# and a configuration.nix, then the rebuild commands run for real. nixpkgs is the
# pinned one, locked with --override-input before the first build, so the systems
# match the running one and nothing is fetched from GitHub.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/nixos.sh"

NOTE=linux/distributions/nixos/basics
SYS=$(uname -m)-linux
NIXPKGS=$(nix eval --impure --raw --expr '(builtins.getFlake "path:/repo/tests/nixos").inputs.nixpkgs.outPath')
OVERRIDE=(--override-input nixpkgs "path:$NIXPKGS")
work=$(mktemp -d)
cd "$work"
# A note line without its trailing comment and sudo (the test runs as root).
line() { note_block "$NOTE" "$1" "$2" | sed -n "${3}p" | sed 's/^sudo //; s/[[:space:]][[:space:]]*# .*$//'; }
marker() { cat /etc/marker 2>/dev/null || echo none; }
gens() { nixos-rebuild list-generations 2>/dev/null | tail -n +2 | grep -c .; }
# configuration.nix: the test system, the note's step 1 lines, and a marker file.
write_config() {
  {
    echo '{ modulesPath, pkgs, ... }:'
    echo '{'
    echo '  imports = [ ./base.nix "${modulesPath}/virtualisation/docker-image.nix" ];'
    echo '  networking.resolvconf.enable = false;'
    echo "  environment.etc.marker.text = \"$1\";"
    note_block "$NOTE" "From a fresh install" 2
    echo '}'
  } >/etc/nixos/configuration.nix
}

section "Installing"
skip "partition, mount, nixos-install, reboot" "needs real disks and a reboot; the installer ISO test (automated-install) does this in a VM"
check "nixos-generate-config --root writes the files" nixos-generate-config --root "$work/r"
assert_file "hardware-configuration.nix" "$work/r/etc/nixos/hardware-configuration.nix"
assert_file "configuration.nix" "$work/r/etc/nixos/configuration.nix"
check_output "the hardware file sets nixpkgs.hostPlatform (the ARM note)" "nixpkgs.hostPlatform = lib.mkDefault \"$SYS\"" \
  cat "$work/r/etc/nixos/hardware-configuration.nix"
check_output "a generated configuration.nix has no flakes setting" '^0$' \
  bash -c "grep -c experimental-features '$work/r/etc/nixos/configuration.nix' || true"

section "From a fresh install to a flake"
check_output "with flakes off, nix search fails with the note's message" "experimental Nix feature 'nix-command' is disabled" \
  bash -c 'NIX_CONFIG="experimental-features =" nix search nixpkgs vim 2>&1; true'
check_output "nixos-rebuild --flake with no flake.nix: the note's message" 'could not find a flake.nix file' \
  bash -c 'nixos-rebuild switch --flake /etc/nixos 2>&1; true'
check_output "step 1 evaluates" '"flakes"' nixos_eval --host --block "From a fresh install" 2 nix.settings.experimental-features
check_output "a second environment.systemPackages in one file is an error" 'already defined' \
  bash -c "nix-instantiate --parse --expr '{ $(note_block "$NOTE" "From a fresh install" 2 | tr '\n' ' ') environment.systemPackages = [ ]; }' 2>&1; true"
check_output "step 2: nixos-version gives the release" '^26\.05\.' nixos-version
check_output "uname -m gives the system" '^(x86_64|aarch64)$' uname -m
hostname nixos
cp /repo/tests/nixos/base.nix /etc/nixos/base.nix
rm -f /etc/nixos/configuration.nix
write_config v1
note_block "$NOTE" "From a fresh install" 5 | sed "s/\"x86_64-linux\"/\"$SYS\"/" >/etc/nixos/flake.nix
nix flake lock /etc/nixos "${OVERRIDE[@]}" 2>/dev/null
check "step 4: nixos-rebuild switch --flake /etc/nixos (from the note)" bash -ec "$(line "From a fresh install" 6 1)"
assert_eq "the configuration is active" v1 "$(marker)"
check "the explicit #nixos form (from the note)" bash -ec "$(line "From a fresh install" 6 2)"
check_output "nix flake commands act on the current directory" 'nixosConfigurations' bash -c 'cd /etc/nixos && nix flake show 2>&1'
write_config v2
check "a plain nixos-rebuild switch" nixos-rebuild switch
assert_eq "uses /etc/nixos/flake.nix, not the channel (the correction)" v2 "$(marker)"

section "The output name must match the hostname"
hostname web-01
check_output "without #name, the output is looked up by hostname" 'nixosConfigurations\."web-01"' \
  bash -c 'nixos-rebuild build 2>&1; true'
check "with #nixos it builds" bash -c 'nixos-rebuild build --flake /etc/nixos#nixos >/dev/null 2>&1'
hostname nixos

section "The rebuild commands"
n=$(gens)
write_config v3
check "nixos-rebuild test (from the note)" bash -ec "$(line "The rebuild commands" 1 3)"
assert_eq "test activates the new configuration" v3 "$(marker)"
assert_eq "but adds no generation" "$n" "$(gens)"
write_config v4
check "nixos-rebuild boot (from the note)" bash -ec "$(line "The rebuild commands" 1 2)"
assert_eq "boot does not activate it" v3 "$(marker)"
assert_eq "but adds a generation" "$((n + 1))" "$(gens)"
assert_eq "the boot default (system profile) has it" v4 "$(cat /nix/var/nix/profiles/system/etc/marker)"
check "nixos-rebuild build (from the note)" bash -ec "$(line "The rebuild commands" 1 4)"
assert_link "build leaves ./result" result "$(readlink result)"
assert_eq "./result is the new system" v4 "$(cat result/etc/marker)"
check_output "nixos-rebuild dry-build (from the note)" 'building the system configuration' \
  bash -ec "$(line "The rebuild commands" 1 5) 2>&1"
write_config v5
check "nixos-rebuild switch (from the note)" bash -ec "$(line "The rebuild commands" 1 1)"
assert_eq "switch activates" v5 "$(marker)"
assert_eq "and adds a generation" "$((n + 2))" "$(gens)"
check "nixos-rebuild switch --rollback (from the note)" bash -ec "$(line "The rebuild commands" 1 6)"
assert_eq "rollback goes back to the previous generation" v4 "$(marker)"
skip "deploying with --target-host" "needs a second machine over SSH"
rebuild_py=$(dirname "$(readlink -f "$(command -v nixos-rebuild)")")/../lib
check_output "--sudo is a nixos-rebuild option" '"--sudo"' grep -rh -- '"--sudo"' "$rebuild_py"

section "Generations"
check_output "nixos-rebuild list-generations (from the note)" 'Generation' bash -c "$(line "## Generations" 1 1)"
check_output "nix-env --list-generations on the system profile (from the note)" '\(current\)' bash -c "$(line "## Generations" 1 2)"
check_output "configurationLimit evaluates" '^20$' nixos_eval --host --block "## Generations" 2 boot.loader.systemd-boot.configurationLimit

section "Channels"
check "nix-channel --add (from the note)" bash -ec "$(line "Channels — the traditional way" 1 2)"
check_output "nix-channel --list (from the note)" 'nixos https://nixos.org/channels/nixos-26.05' bash -ec "$(line "Channels — the traditional way" 1 1)"
skip "nix-channel --update and switch --upgrade" "download and build a different nixpkgs; the flake steps above cover rebuilds"

section "Daily flake commands"
mkdir -p "$work/repo/hosts" && cd "$work/repo"
git init -q && git config user.email t@example.com && git config user.name t
printf '{ outputs = _: { web02 = import ./hosts/web-02.nix; }; }\n' >flake.nix
echo '"ok"' >hosts/web-02.nix
git add flake.nix
check_output "an untracked file is not seen by the flake (the warning)" 'does not exist|not tracked|No such file' \
  bash -c 'nix eval .#web02 2>&1; true'
git add hosts/web-02.nix
check_output "staged is enough" '^"ok"$' nix eval .#web02
cd "$work"
check_output "nixos-option uses /etc/nixos/flake.nix too (from the note)" 'Value:' \
  bash -c "$(note_block "$NOTE" "Finding packages" 2 | sed -n 2p)"
check_output "nixos-option -r on a small part (from the note)" 'PasswordAuthentication' \
  bash -c "$(note_block "$NOTE" "Finding packages" 2 | sed -n 3p)"
check_output "-r services.nginx stops on a renamed option (the correction)" 'Renaming error' \
  bash -c 'nixos-option -r services.nginx 2>&1; true'
check_output "man configuration.nix exists when documentation is on" '^true$' \
  nixos_eval --host 'documentation.nixos.enable'
skip "nix search nixpkgs firefox" "evaluates all of nixpkgs (several GB of memory); the next check uses the same flake reference"
check_output "the --extra-experimental-features form, with flakes off" '^"firefox' \
  bash -c "NIX_CONFIG='experimental-features =' nix --extra-experimental-features 'nix-command flakes' eval nixpkgs#firefox.name"
# Last, because it moves /etc/nixos to the latest nixpkgs of the branch (GitHub).
out=$(bash -c "$(line "Daily flake commands" 1 2)" 2>&1) && ok=yes || ok=no
if [[ $ok == no ]] && grep -q 'rate limit' <<<"$out"; then
  skip "nix flake update one input (from the note)" "the GitHub API refused: rate limit, no token here"
else
  assert_eq "nix flake update one input (from the note)" yes "$ok"
  check_output "the lock now follows the github branch" '^github$' jq -r '.nodes.nixpkgs.locked.type' /etc/nixos/flake.lock
fi

section "Temporary shells"
check_output "nix-shell -p (channels; here NIX_PATH points to the flake)" '^jq-1' \
  bash -c "$(line "Temporary shells" 1 1) --run 'jq --version'"
check_output "nix shell nixpkgs#python3 (from the note)" '^Python 3' bash -c "$(line "Temporary shells" 1 2) --command python3 --version"
mkdir -p "$work/proj" && cd "$work/proj"
note_block "$NOTE" "Temporary shells" 2 | sed "s/x86_64-linux/$SYS/g" >flake.nix
nix flake lock "${OVERRIDE[@]}" 2>/dev/null
check_output "nix develop gives the pinned Go (from the note)" 'go1\.26' \
  bash -c "$(line "Temporary shells" 3 1) --command go version"
check_output "and golangci-lint" 'golangci-lint has version' nix develop --command golangci-lint --version
cd "$work"

section "Garbage collection"
check_output "nix.gc block evaluates" '"weekly"' nixos_eval --host --block "Garbage collection" 2 nix.gc.dates
check_output "auto-optimise-store" '^true$' nixos_eval --host --block "Garbage collection" 2 nix.settings.auto-optimise-store
before=$(gens)
check "nix-store --gc (from the note)" bash -ec "$(line "Garbage collection" 1 1) >/dev/null 2>&1"
check "nix-collect-garbage --delete-older-than 30d (from the note)" bash -ec "$(line "Garbage collection" 1 3) >/dev/null 2>&1"
assert_eq "keeps the recent generations" "$before" "$(gens)"
check "nix-collect-garbage -d (from the note)" bash -ec "$(line "Garbage collection" 1 2) >/dev/null 2>&1"
assert_eq "-d leaves one generation: the rollback targets are gone (the warning)" 1 "$(gens)"
check_output "du -sh /nix/store" '/nix/store' bash -c "$(line "Garbage collection" 1 4)"
