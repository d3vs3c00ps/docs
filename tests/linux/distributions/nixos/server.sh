#!/usr/bin/env bash
# note: linux/distributions/nixos/server.md
# env: nixos
# timeout: 2400
# The service blocks are evaluated as a normal host (ACME and a public nginx do not
# run in a container). The store, the secrets advice and the image build run for real.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/nixos.sh"

NOTE=linux/distributions/nixos/server
NIXPKGS=$(nix eval --impure --raw --expr '(builtins.getFlake "path:/repo/tests/nixos").inputs.nixpkgs.outPath')
cd "$(mktemp -d)"
TOP=system.build.toplevel.drvPath
evm() { NIXOS_MODULE="{ notes, pkgs, lib, config, ... }: { imports = [ $1 ]; }" nixos_eval --host "$2"; }
evj() { evm "$1" "$2" | jq -cS .; }
m() { echo "(notes.module \"$1\" ${2:-1})"; }
# A block with its free variables replaced: myapp is hello, configFile a small file.
fixed() {
  note_block "$NOTE" "$1" "${2:-1}" | sed 's|\${pkgs.myapp}/bin/myapp --config \${configFile}|${pkgs.hello}/bin/hello|' >"$PWD/$3"
  sed -i '1s/^{/{ pkgs, config, ... }: {/' "$PWD/$3"
  echo "$PWD/$3"
}

section "Services"
SVC=$(m "## Services" 1)
check "the services block evaluates" evm "$SVC" $TOP
check_output "nginx proxies / to 127.0.0.1:8080" '^"http://127\.0\.0\.1:8080"$' evm "$SVC" 'services.nginx.virtualHosts."example.com".locations."/".proxyPass'
check_output "an ACME certificate for example.com" '^"example\.com"$' evm "$SVC" 'security.acme.certs."example.com".domain'
check_output "PostgreSQL 16" '^"16' evm "$SVC" services.postgresql.package.version
check_output "the firewall opens 80 and 443" '\[80,443\]' evj "$SVC" networking.firewall.allowedTCPPorts
n=$(nix eval --impure --expr "let f = builtins.getFlake \"path:/repo/tests/nixos\"; s = f.lib.system { container = false; }; lib = f.inputs.nixpkgs.lib; in builtins.length (lib.collect lib.isOption s.options)" 2>/dev/null || echo 0)
check "the module library has roughly 20,000 options ($n)" test "$n" -gt 15000

section "Hardening"
H=$(m "## Hardening" 1)
check "the hardening block evaluates" evm "$H" $TOP
check_output "sshd: no password, no root" '"PasswordAuthentication":false.*"PermitRootLogin":"no"' \
  evj "$H" services.openssh.settings
check_output "fail2ban is on" '^true$' evm "$H" services.fail2ban.enable
check_output "autoUpgrade at 04:00" '04:00' evm "$H" systemd.timers.nixos-upgrade.timerConfig.OnCalendar

section "Custom services"
CS=$(fixed "Custom services" 1 custom.nix)
check "the custom service evaluates (with hello as myapp)" evm "$CS $(m '## Services' 1)" $TOP
check_output "it requires postgresql" 'postgresql\.service' evm "$CS $(m '## Services' 1)" systemd.services.myapp.requires
check_output "with ProtectSystem=strict and a StateDirectory" '"ProtectSystem":"strict".*"StateDirectory":"myapp"' \
  evj "$CS $(m '## Services' 1)" systemd.services.myapp.serviceConfig

section "Secrets"
check_output "the store directory is 1775 root:nixbld, not 555" '^1775 root nixbld$' stat -c '%a %U %G' /nix/store
f=$(nix-build --no-out-link -E '(import <nixpkgs> {}).writeText "myapp.conf" "token=s3cret"' 2>/dev/null)
check_output "but every file in it is readable by any user" 's3cret' runuser -u nobody -- cat "$f"
check "the systemd credentials block evaluates" evm "$(m Secrets 2)" $TOP
SOPS='(builtins.getFlake "github:Mic92/sops-nix").nixosModules.sops'
check_output "the sops-nix block passes the secret with LoadCredential" '^"db-password:/run/secrets/db/password"$' \
  evm "$SOPS $(m Secrets 3)" systemd.services.myapp.serviceConfig.LoadCredential
printf 's3cret\n' >/run/pw && chmod 600 /run/pw
out=$(systemd-run --wait --pipe -p EnvironmentFile=/run/pw env 2>&1)
assert_no_match "EnvironmentFile with a bare password sets no variable (the correction)" 's3cret' "$out"
check_output "LoadCredential gives the service the file" '^s3cret$' \
  systemd-run --wait --pipe -p LoadCredential=db-password:/run/pw bash -c 'read -r l <"$CREDENTIALS_DIRECTORY/db-password"; echo "$l"'

section "Deployment"
h=$(nixos-rebuild --help 2>&1 || true)
for o in --target-host --build-host --flake; do assert_match "nixos-rebuild has $o" -- "$o" "$h"; done
mkdir -p fleet/hosts/web-01 fleet/hosts/db-01 fleet/modules
for x in web-01 db-01; do
  echo '{ boot.loader.grub.device = "nodev"; fileSystems."/".device = "/dev/sda1"; system.stateVersion = "26.05"; }' >fleet/hosts/$x/default.nix
done
echo '{ }' >fleet/modules/common.nix
note_block "$NOTE" Deployment 2 | sed "1s|^{|{ inputs.nixpkgs.url = \"path:$NIXPKGS\";|" >fleet/flake.nix
check_output "the fleet flake block evaluates (two hosts)" '^\["db-01","web-01"\]$' \
  nix eval --json "path:$PWD/fleet#nixosConfigurations" --apply builtins.attrNames
check_output "web-01 gets the common module and its host file" '\.drv$' \
  nix eval --raw "path:$PWD/fleet#nixosConfigurations.web-01.config.system.build.toplevel.drvPath"

check_output "the note's command uses --target-host only" '^nixos-rebuild switch --flake \.#web-01 --target-host root@web-01$' \
  note_block "$NOTE" Deployment 1
mkdir -p local
cat >local/flake.nix <<NIX
{ inputs.nixpkgs.url = "path:$NIXPKGS";
  outputs = { nixpkgs, ... }: { nixosConfigurations.t = nixpkgs.lib.nixosSystem {
    system = "$(uname -m)-linux";
    modules = [ { boot.loader.grub.device = "nodev"; fileSystems."/".device = "/dev/sda1"; system.stateVersion = "26.05"; } ];
  }; }; }
NIX
out=$(cd local && timeout 300 nixos-rebuild build --flake "path:$PWD#t" --build-host localhost 2>&1) && ok=yes || ok=no
assert_eq "the correction: --build-host localhost fails here (no sshd)" no "$ok"
assert_match "because it goes through ssh" '[Ss][Ss][Hh]' "$out"

section "Building images"
imgs=$(nix eval --impure --json --expr '((builtins.getFlake "path:/repo/tests/nixos").lib.system { container = false; }).config.system.build.images' --apply builtins.attrNames)
for v in qemu-efi amazon iso; do assert_match "image variant $v exists" "\"$v\"" "$imgs"; done
assert_no_match "there is no qcow2 variant" '"qcow2"' "$imgs"
assert_no_match "and no docker variant" '"docker"' "$imgs"
check_output "nixos-rebuild has build-image" 'build-image' bash -c 'nixos-rebuild --help 2>&1'

section "Containers"
img=$(nix-build --no-out-link -E "with import <nixpkgs> {}; $(note_block "$NOTE" Containers 1 | sed 's/pkgs\.myapp/pkgs.hello/; s|/bin/myapp|/bin/hello|')" 2>/dev/null) || img=
check "dockerTools.buildLayeredImage builds the image (hello as myapp)" test -s "$img"
check_output "a docker-archive tarball" 'manifest\.json' tar -tzf "$img"
check "the nspawn container block evaluates" evm "$(m Containers 2)" $TOP
check_output "as container@mycontainer" 'systemd-nspawn' evm "$(m Containers 2)" 'systemd.services."container@mycontainer".script'
