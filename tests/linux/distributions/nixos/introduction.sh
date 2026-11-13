#!/usr/bin/env bash
# note: linux/distributions/nixos/introduction.md
# env: nixos
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/nixos.sh"

NOTE=linux/distributions/nixos/introduction
cd "$(mktemp -d)"

section "The one idea everything follows from"
hn=$(nixos_eval networking.hostName | tr -d '"')
check_output "/run/current-system is a symlink into the store (from the note)" \
  "-> /nix/store/[a-z0-9]{32}-nixos-system-$hn-26\.05\." bash -c "$(note_block "$NOTE" "The one idea" 2)"
check_output "store paths are named <hash>-<name>-<version>" '^/nix/store/[a-z0-9]{32}-openssl-[0-9]' \
  bash -c 'nix path-info -r /run/current-system | grep -- "-openssl-[0-9][0-9.]*$" | head -1'

section "What a system looks like"
# The note's file without its import of hardware-configuration.nix, which a test has
# not. Extra strings to remove can be given as Nix strings.
intro_module() {
  echo "{ notes, lib, ... }: { imports = [ (import (builtins.toFile \"configuration.nix\"
    (lib.replaceStrings [ \"imports = [ ./hardware-configuration.nix ];\" $1 ] [ \"\" ${1:+\"\"} ]
      (notes.block \"What a system looks like\" 1)))) ]; }"
}
export NIXOS_MODULE
NIXOS_MODULE=$(intro_module "")
check_output "the configuration evaluates to a system" '\.drv"$' nixos_eval --host system.build.toplevel.drvPath
check_output "nginx gets the virtual host, with ACME" '^true$' nixos_eval --host 'services.nginx.virtualHosts."example.com".enableACME'
check_output "SSH passwords are off" '^false$' nixos_eval --host services.openssh.settings.PasswordAuthentication
check_output "alice is in wheel" 'wheel' nixos_eval --host users.users.alice.extraGroups
# The correction: without security.acme, enableACME does not build.
NIXOS_MODULE=$(intro_module '"acceptTerms = true;"')
out=$(nixos_eval --host system.build.toplevel.drvPath 2>&1) && ok=yes || ok=no
assert_eq "without security.acme.acceptTerms it does not build" no "$ok"
assert_match "and says why" 'acceptTerms' "$out"
unset NIXOS_MODULE
check_output "nixos-rebuild is there" 'nixos-rebuild' command -v nixos-rebuild

section "Generations"
gens=$(note_block "$NOTE" Generations 1)
check_output "nixos-rebuild list-generations (from the note)" 'Generation.*Current' bash -c "$(sed -n 1p <<<"$gens")"
check_output "nix-env --list-generations on the system profile (from the note)" '\(current\)' \
  bash -c "$(sed -n 2p <<<"$gens" | sed 's/^sudo //')"
skip "nixos-rebuild switch --rollback" "a second generation is built and rolled back in basics.sh"

section "What you give up"
assert_eq "/usr/bin holds only env (the correction)" "env" "$(ls /usr/bin)"
assert_eq "/bin holds sh" "sh" "$(find /bin -mindepth 1 -maxdepth 1 -name sh -printf '%f')"
assert_no_file "there is no /lib64" /lib64
check "so #!/usr/bin/env bash works" bash -c 'printf "#!/usr/bin/env bash\necho ok\n" >s && chmod +x s && ./s'
# A copy of ls that asks for the loader a generic Linux binary expects.
case $(uname -m) in
  x86_64) ld=/lib64/ld-linux-x86-64.so.2 ;;
  aarch64) ld=/lib/ld-linux-aarch64.so.1 ;;
esac
cp "$(readlink -f "$(command -v ls)")" ./generic-ls && chmod u+w generic-ls
nix shell nixpkgs#patchelf --command patchelf --set-interpreter "$ld" generic-ls
check_output "a binary built for a normal distribution fails at once" 'No such file or directory|required file not found' \
  bash -c './generic-ls 2>&1; true'
check_fails "and does not run" ./generic-ls
check_output "buildFHSEnv exists (the correction)" '^true$' nix eval --impure --expr '(import <nixpkgs> { }) ? buildFHSEnv'
check_output "buildFHSUserEnv is gone" '^false$' nix eval --impure --expr '(import <nixpkgs> { }) ? buildFHSUserEnv'
check_output "steam-run is packaged" '^"steam-run' nix eval nixpkgs#steam-run.name
check_output "nix-ld is a NixOS option" '^false$' nixos_eval programs.nix-ld.enable
check_output "flakes are still experimental: off, nix flake fails" "experimental Nix feature 'flakes' is disabled|experimental Nix feature 'nix-command' is disabled" \
  bash -c 'NIX_CONFIG="experimental-features = nix-command" nix flake metadata /tmp 2>&1; true'

section "Nix without NixOS"
check_output "nix develop is a nix command" 'develop' nix develop --help
