#!/usr/bin/env bash
# note: linux/distributions/nixos/derivations.md
# env: nixos
# timeout: 1800
# Runs on the base NixOS system: nix, the store, /run/current-system. Packages come
# from the pinned nixpkgs and cache.nixos.org.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/nixos.sh"

NOTE=linux/distributions/nixos/derivations
cd "$(mktemp -d)"
SYS=$(nix eval --impure --raw --expr builtins.currentSystem)

section "Two phases"
drv=$(nix-instantiate '<nixpkgs>' -A hello 2>/dev/null)
assert_match "nix-instantiate gives a .drv, nothing built (from the note)" '^/nix/store/[a-z0-9]{32}-hello-2\.12\.3\.drv$' "$drv"
assert_eq "the note shows the current hello version" "hello-2.12.3" "$(note_block "$NOTE" "Two phases" 2 | sed -n 's|.*xxxx-\(hello-[0-9.]*\)\.drv.*|\1|p' | sort -u)"
check_fails "evaluation did not build hello" test -e "$(nix-store -q --outputs "$drv")"
check_output "nix derivation show on the .drv" '"derivations"' nix derivation show "$drv"

section "What a derivation contains"
cmd=$(note_block "$NOTE" "What a derivation contains" 1)
out=$(bash -c "$cmd" 2>&1) && ok=yes || ok=no
assert_eq "the note's jq filter runs (format version 4)" yes "$ok"
for k in name outputs inputDrvs env; do assert_match "it prints $k" "\"$k\"" "$out"; done
check_output "the old filter '.[] | .inputDrvs' fails now (the correction)" 'error' \
  bash -c "nix derivation show nixpkgs#hello | jq '.[] | {inputDrvs: (.inputDrvs|keys)}' 2>&1; true"
fields=$(nix derivation show nixpkgs#hello | jq -r '.derivations[] | keys[]' | tr '\n' ' ')
for f in name system builder args env outputs; do assert_match "a derivation has $f" "(^| )$f " "$fields"; done
check_output "inputs has drvs and srcs" '^drvs srcs$' \
  bash -c "nix derivation show nixpkgs#hello | jq -r '.derivations[].inputs | keys | join(\" \")'"
check_output "the builder is bash" '/bin/bash$' bash -c "nix derivation show nixpkgs#hello | jq -r '.derivations[].builder'"

section "Writing one"
printf 'echo built > $out\n' >builder.sh
prim=$(note_block "$NOTE" "Writing one" 1 | sed "s/x86_64-linux/$SYS/")
out=$(nix-build --no-out-link -E "let pkgs = import <nixpkgs> { }; in $prim" 2>/dev/null)
check_output "the primitive derivation builds; its builder writes \$out (from the note)" '^built$' cat "$out"
mkdir -p myapp-1.2.3
printf 'cmake_minimum_required(VERSION 3.10)\nproject(myapp C)\nadd_executable(myapp main.c)\ninstall(TARGETS myapp)\n' >myapp-1.2.3/CMakeLists.txt
printf '#include <stdio.h>\nint main(void) { puts("myapp ok"); return 0; }\n' >myapp-1.2.3/main.c
tar -czf myapp-1.2.3.tar.gz myapp-1.2.3
note_block "$NOTE" "Writing one" 2 >myapp-note.nix
fake=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
sed "s|sha256-AAAA\.\.\.|$fake|" myapp-note.nix >myapp-eval.nix
check_output "the mkDerivation example evaluates with callPackage" '\.drv$' \
  nix-instantiate -E 'with import <nixpkgs> { }; callPackage ./myapp-eval.nix { }'
check_output "finalAttrs: overriding version changes the URL" 'myapp-2\.0\.tar\.gz' \
  nix-instantiate --eval -E 'with import <nixpkgs> { }; ((callPackage ./myapp-eval.nix { }).overrideAttrs { version = "2.0"; }).src.url'
# The same file with a local tarball instead of fetchurl, to build it for real.
awk '/src = fetchurl/ { print "  src = ./myapp-1.2.3.tar.gz;"; skip = 1; next }
     skip && /^  };/ { skip = 0; next } !skip' myapp-note.nix >myapp.nix
log=$(nix-build --no-out-link -E 'with import <nixpkgs> { }; callPackage ./myapp.nix { }' 2>&1) && built=yes || built=no
assert_eq "it builds a CMake project with no explicit phases" yes "$built"
assert_match "the configure phase ran cmake with the \$out prefix" 'cmake flags: .*-DCMAKE_INSTALL_PREFIX=/nix/store/' "$log"
out=$(tail -1 <<<"$log")
check_output "make install put the binary in \$out" '^myapp ok$' "$out/bin/myapp"
check_output "a name missing from the arguments does not evaluate" "undefined variable 'cmake'" \
  bash -c "sed 's/fetchurl, cmake, /fetchurl, /' myapp-eval.nix >bad.nix; nix-instantiate -E 'with import <nixpkgs> { }; callPackage ./bad.nix { }' 2>&1; true"

section "The build sandbox"
check_output "sandbox is on (the default on Linux)" '^true$' nix config show sandbox
check_output "the note's setting evaluates" '^true$' nixos_eval --host --block "The build sandbox" 1 nix.settings.sandbox
check_output "a normal build has no network" 'Could not resolve|resolve host|network' \
  bash -c "nix-build --no-out-link -E 'with import <nixpkgs> { }; runCommand \"net\" { } \"\${curl}/bin/curl -sS https://cache.nixos.org >\$out\"' 2>&1; true"
fod="derivation { name = \"x\"; system = \"$SYS\"; builder = \"/bin/sh\"; args = [ \"-c\" \"echo hi > \$out\" ]; outputHash = \"$fake\"; }"
out=$(nix-build --no-out-link -E "$fod" 2>&1 || true)
assert_match "a wrong fixed-output hash fails with the note's message" 'hash mismatch in fixed-output derivation' "$out"
assert_match "it shows the specified hash" "specified: $fake" "$out"
got=$(sed -n 's/.*got: *\(sha256-[^ ]*\).*/\1/p' <<<"$out")
assert_match "and the hash it got" '^sha256-' "$got"
check "with the 'got' value, the build passes" nix-build --no-out-link -E "${fod/$fake/$got}"

section "Reproducibility, honestly"
check "nix build nixpkgs#hello" nix build --no-link nixpkgs#hello
check "--rebuild builds it again and finds the same bytes (from the note)" \
  bash -ec "$(note_block "$NOTE" "Reproducibility, honestly" 1 | sed -n 1p) --no-link"
check_output "nix store diff-closures compares two systems" 'hello|nixos-system|→|ε' \
  nix store diff-closures /run/current-system "$(nix build --no-link --print-out-paths nixpkgs#hello)"

section "Closures"
check_output "nix path-info -r lists the closure (from the note)" '^/nix/store/' \
  bash -c "$(note_block "$NOTE" Closures 1 | sed -n 1p)"
check_output "nix path-info -Sh gives the closure size" '[0-9.]+ [KM]iB' bash -c "$(note_block "$NOTE" Closures 1 | sed -n 2p)"
check_output "why-depends prints the chain to perl (from the note)" 'perl-' bash -c "$(note_block "$NOTE" Closures 1 | sed -n 3p)"
check_output "without ^out it refuses: perl is several store paths" 'should evaluate to one store path' \
  bash -c 'nix why-depends /run/current-system nixpkgs#perl 2>&1; true'
sys=$(readlink -f /run/current-system)
check_output "nix-store --query --references" '^/nix/store/' nix-store --query --references "$sys"
bash_path=$(readlink -f "$(command -v bash)" | cut -d/ -f1-4)
check_output "--referrers" '^/nix/store/' nix-store --query --referrers "$bash_path"
check_output "--roots shows why GC keeps the system" 'profiles/system|current-system' nix-store --query --roots "$sys"

section "Binary caches"
check_output "the substituters evaluate" 'cache.nixos.org.*myorg.cachix.org' nixos_eval --host --block "Binary caches" 1 nix.settings.substituters
check_output "one key per cache" 'cache.nixos.org-1:.*myorg.cachix.org-1:' nixos_eval --host --block "Binary caches" 1 nix.settings.trusted-public-keys
key=$(note_block "$NOTE" "Binary caches" 1 | grep -o 'cache.nixos.org-1:[^"]*')
assert_match "the cache.nixos.org key in the note is the one NixOS trusts" "$key" "$(nix config show trusted-public-keys)"
