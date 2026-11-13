#!/usr/bin/env bash
# note: linux/distributions/nixos/workstation.md
# env: nixos
# timeout: 2400
# A desktop cannot run in a container: the blocks are evaluated as a normal host, as
# whole systems. The dev shell is built and entered.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/nixos.sh"

NOTE=linux/distributions/nixos/workstation
SYS=$(uname -m)-linux
NIXPKGS=$(nix eval --impure --raw --expr '(builtins.getFlake "path:/repo/tests/nixos").inputs.nixpkgs.outPath')
cd "$(mktemp -d)"
TOP=system.build.toplevel.drvPath
# evm MODULES ATTR: evaluate a host made of these modules (Nix list items).
evm() { NIXOS_MODULE="{ notes, pkgs, lib, ... }: { imports = [ $1 ]; }" nixos_eval --host "$2"; }
m() { echo "(notes.module \"$1\" ${2:-1})"; }
UNFREE='{ nixpkgs.config.allowUnfree = true; }'
# evq MODULES ATTR JQ: the same, filtered with jq.
evq() { evm "$1" "$2" | jq -cSr "$3"; }

section "Desktop environment"
check "the GNOME block evaluates" evm "$(m "## Desktop environment" 1)" $TOP
check_output "with the fr azerty layout" '"layout":"fr".*"variant":"azerty"' \
  evq "$(m "## Desktop environment" 1)" services.xserver.xkb '{layout, variant}'
check_output "GNOME does not turn on the X server" '^false$' evm "$(m "## Desktop environment" 1)" services.xserver.enable
check "the Plasma block evaluates" evm "$(m "## Desktop environment" 2)" $TOP
out=$(evm "$(m "## Desktop environment" 1) $(m "## Desktop environment" 2)" $TOP 2>&1) && ok=yes || ok=no
assert_eq "both in one configuration does not build (the correction)" no "$ok"
assert_match "the error is about the display managers" 'display ?[mM]anager|gdm|sddm' "$out"
check "programs.sway evaluates" evm "$(m "## Desktop environment" 3)" $TOP

section "Audio, printing, Bluetooth"
check "the block evaluates" evm "$(m "Audio, printing" 1)" $TOP
check_output "PipeWire replaces PulseAudio" '^false$' evm "$(m "Audio, printing" 1)" services.pulseaudio.enable
check_output "Avahi resolves .local names (nssmdns4)" '^true$' evm "$(m "Audio, printing" 1)" services.avahi.nssmdns4

section "Graphics and firmware"
check "the NVIDIA block evaluates with allowUnfree" evm "$(m "Graphics and firmware" 1) $UNFREE" $TOP
out=$(evm "$(m "Graphics and firmware" 1)" $TOP 2>&1) && ok=yes || ok=no
assert_eq "without the opt-in, unfree packages refuse to build" no "$ok"
assert_match "with the 'unfree license' message" 'unfree license' "$out"
check "the predicate block, with the note's names, is enough for the NVIDIA block" \
  evm "$(m "Graphics and firmware" 1) $(m "Graphics and firmware" 2)" $TOP
out=$(NIXOS_MODULE="{ notes, lib, ... }: { imports = [ $(m "Graphics and firmware" 1) ];
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ \"nvidia-x11\" ]; }" \
  nixos_eval --host $TOP 2>&1) && ok=yes || ok=no
assert_eq "nvidia-x11 alone is not enough (the note's added name)" no "$ok"
assert_match "the error names nvidia-settings" 'nvidia-settings' "$out"

section "Laptop concerns"
check "the laptop block evaluates" evm "$(m "Laptop concerns" 1)" $TOP
out=$(evm "$(m "## Desktop environment" 1) $(m "Laptop concerns" 1)" $TOP 2>&1) && ok=yes || ok=no
assert_eq "TLP with GNOME does not build (the warning)" no "$ok"
assert_match "because of power-profiles-daemon" 'power-profiles-daemon' "$out"
check "with power-profiles-daemon off, it builds" \
  evm "$(m "## Desktop environment" 1) $(m "Laptop concerns" 1) { services.power-profiles-daemon.enable = false; }" $TOP

section "home-manager"
check_output "the input URL names the release branch" 'release-26\.05' note_block "$NOTE" home-manager 1
hm=$(nix eval --impure --raw --expr 'builtins.fetchTarball "https://github.com/nix-community/home-manager/archive/release-26.05.tar.gz"')
dot=$PWD/foo.yaml && echo "a: 1" >"$dot"
HM="$hm/nixos { users.users.alice.isNormalUser = true; home-manager.useGlobalPkgs = true; }"
check "the home-manager block evaluates" evm "$HM $(m home-manager 2)" "home-manager.users.alice.home.activationPackage.drvPath"
check_output "programs.git.settings writes ~/.config/git/config" 'email = "?your.name@example.com' \
  evq "$HM $(m home-manager 2)" 'home-manager.users.alice.xdg.configFile."git/config".text' .
check_output "zsh aliases reach .zshrc" "alias -- ll='ls -lah'|alias ll='ls -lah'" \
  evq "$HM $(m home-manager 2)" 'home-manager.users.alice.home.file.".zshrc".text' .
check_output "home.file links a file you keep in the repository" "$dot" \
  evm "$HM { home-manager.users.alice = { lib, ... }: { home.stateVersion = \"26.05\"; imports = [ (import (builtins.toFile \"f.nix\" (\"{ ... }: {\" + builtins.replaceStrings [ \"./dotfiles/foo.yaml\" ] [ \"$dot\" ] (notes.block \"Move to home-manager gradually\" 1) + \"}\"))) ]; }; }" \
  'home-manager.users.alice.home.file.".config/foo/config.yaml".source'

section "Development shells"
mkdir proj && cd proj
note_block "$NOTE" "Development shells" 1 | sed "s/x86_64-linux/$SYS/" >flake.nix
nix flake lock --override-input nixpkgs "path:$NIXPKGS" 2>/dev/null
out=$(nix develop --command bash -c 'go version; golangci-lint --version; postgres --version; kubectl version --client; echo "DB=$DATABASE_URL"' 2>&1) && ok=yes || ok=no
assert_eq "nix develop builds the shell (from the note)" yes "$ok"
assert_match "the shellHook prints the Go version" '^Go go1\.26' "$out"
assert_match "go 1.26" 'go version go1\.26' "$out"
assert_match "golangci-lint" 'golangci-lint has version' "$out"
assert_match "PostgreSQL 16" 'postgres \(PostgreSQL\) 16\.' "$out"
assert_match "kubectl" 'Client Version' "$out"
assert_match "and DATABASE_URL from shellHook" '^DB=postgres://localhost/dev$' "$out"
cd ..
check "the direnv block evaluates" evm "$(m "Development shells" 3)" $TOP
check_output "nix-direnv is on" '^true$' evm "$(m "Development shells" 3)" programs.direnv.nix-direnv.enable

section "Running binaries that expect a normal filesystem"
check "the nix-ld block evaluates" evm "$(m "Running binaries" 1)" $TOP
check_output "nix-ld becomes the loader generic binaries look for" 'nix-ld' \
  evm "$(m "Running binaries" 1)" environment.ldso
check "the Flatpak block evaluates (with a portal)" evm "$(m "Running binaries" 2)" $TOP
out=$(NIXOS_MODULE='{ services.flatpak.enable = true; xdg.portal.enable = true; }' nixos_eval --host $TOP 2>&1) && ok=yes || ok=no
assert_eq "xdg.portal.enable alone does not build (the note's added line)" no "$ok"
assert_match "NixOS asks for a portal" 'extraPortals' "$out"
check_output "steam-run is packaged (from the note)" '^"steam-run' nix eval nixpkgs#steam-run.name
check "the distrobox block evaluates" evm "$(m "Running binaries" 4)" $TOP
