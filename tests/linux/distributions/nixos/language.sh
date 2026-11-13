#!/usr/bin/env bash
# note: linux/distributions/nixos/language.md
# env: nix
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/distributions/nixos/language
cd "$(mktemp -d)"
# The nixpkgs of tests/nixos/flake.lock, already in the notes-nix-store volume.
NIXPKGS='(builtins.getFlake "path:/repo/tests/nixos").inputs.nixpkgs'
ev() { nix-instantiate --eval --strict --json --expr "$1"; }
# blk HEADING N: a block of the note, without its trailing comments.
blk() { note_block "$NOTE" "$1" "${2:-1}" | sed 's/[[:space:]]*#.*$//'; }

section "Getting started"
check_output "nix-instantiate --eval (from the note)" '^2$' bash -ec "$(note_block "$NOTE" "# The Nix language" 1 | sed -n 2p)"

section "Values"
values=$(note_block "$NOTE" Values 1)
for line in 1 2 3 8 9 11 12; do
  v=$(sed -n "${line}p" <<<"$values" | sed 's/[[:space:]]*#.*$//')
  check "'$v' is a value" nix-instantiate --parse --expr "$v"
done
check_output "./relative/path is a path, not a string" '"path"' ev 'builtins.typeOf ./relative/path'
indented=$(sed -n 4,7p <<<"$values" | sed 's/[[:space:]]*#.*$//')
check_output "the indented string loses its leading indentation" '^"multi-line\\nstring\\n"$' ev "$indented"
check_output "a list with commas is a syntax error" "syntax error, unexpected ','" \
  bash -c 'nix-instantiate --parse --expr "[ 1, 2, 3 ]" 2>&1; true'
check_fails "and so is a set without the last semicolon" nix-instantiate --parse --expr '{ a = 1; b = 2 }'

section "Attribute sets"
check_output "person.address.city (from the note)" '^"Paris"$' ev "$(blk "Attribute sets" 1)"
dotted=$(blk "Attribute sets" 2)
a=$(ev "$(sed '/^$/,$d' <<<"$dotted")")
b=$(ev "$(sed '1,/^$/d' <<<"$dotted")")
assert_eq "dotted paths and nested sets are exactly equivalent" "$a" "$b"
check_output "rec lets attributes refer to each other" '"name":"myapp-1.2.3"' ev "$(blk "Attribute sets" 3)"
check_output "'or' gives a default for a missing attribute" '^"none"$' \
  ev "let person = { name = \"Alice\"; }; in $(blk "Attribute sets" 4)"

section "String interpolation"
check_output "\${} interpolates (from the note)" '^"hello world"$' ev "$(blk "String interpolation" 1)"
check_output "\$name is a literal dollar sign" '^"\$name"$' ev 'let name = "world"; in "$name"'
check_output "''\${ escapes \${ in an indented string" '^"\$\{name\}"$' ev "let name = \"x\"; in ''''\${name}''"

section "Functions"
check_output "(x: x + 1) 5 gives 6" '^6$' ev "$(blk Functions 1 | sed -n 2p)"
check_output "curried x: y: x + y" '^5$' ev "($(blk Functions 1 | sed -n 4p)) 2 3"
f=$(blk Functions 2)
check_output "the default greeting applies" '^"Hello, Alice!"$' ev "($f) { name = \"Alice\"; }"
check_output "without ..., an extra attribute is an error" 'unexpected argument' \
  bash -c "nix-instantiate --eval --expr '($f) { name = \"A\"; extra = 1; }' 2>&1; true"
check_output "with ..., it is ignored" '^"ok"$' ev '({ name, ... }: "ok") { name = "A"; extra = 1; }'

section "let and with"
check_output "let ... in (from the note)" '^3$' ev "$(blk "and \`with\`" 1)"
check_output "with pkgs; [ vim git htop ] (from the note)" '"vim-.*git-.*htop-' \
  ev "let pkgs = import $NIXPKGS { }; in map (p: p.name) ($(blk "and \`with\`" 2))"
out=$(nix-instantiate --eval --strict --expr 'let pkgs = { vim = 1; git = 2; }; in with pkgs; [ vim gti ]' 2>&1 || true)
assert_match "with: a typo is an 'undefined variable'" "undefined variable 'gti'" "$out"
col=$(grep -oE 'string»:1:[0-9]+' <<<"$out" | cut -d: -f3)
src='let pkgs = { vim = 1; git = 2; }; in with pkgs; [ vim gti ]'
assert_eq "the error points at gti, not at with (the correction)" "gti" "${src:col-1:3}"
assert_no_match "with: no 'Did you mean' hint" 'Did you mean' "$out"
check_output "without with, Nix suggests the right name" 'Did you mean git' \
  bash -c 'nix-instantiate --eval --strict --expr "let pkgs = { vim = 1; git = 2; }; in [ pkgs.vim pkgs.gti ]" 2>&1; true'
check_fails "without with, a typo fails at parse time" nix-instantiate --parse --expr 'let vim = 1; in [ vim gti ]'
check "with with, the same file parses" nix-instantiate --parse --expr 'with { vim = 1; }; [ vim gti ]'

section "Laziness"
check_output "the unused throw is never evaluated" '^42$' ev "$(blk Laziness 1)"

section "Useful builtins and lib"
b=$(note_block "$NOTE" "Useful builtins" 1)
check_output "builtins.length [ 1 2 3 ] is 3" '^3$' ev "$(sed -n 1p <<<"$b" | sed 's/#.*//')"
check_output "builtins.toString 42" '^"42"$' ev "$(sed -n 2p <<<"$b")"
check_output "builtins.fromJSON" '^\{"a":1\}$' ev "$(sed -n 4p <<<"$b")"
check_output "builtins.currentSystem works in nix-instantiate" 'linux' ev 'builtins.currentSystem'
check_output "but not in pure mode (nix eval), as the note says" "attribute 'currentSystem' missing" \
  bash -c 'nix eval --expr builtins.currentSystem 2>&1; true'
for fn in mkIf mkDefault mkForce mkMerge optionals mapAttrs debug.traceVal; do
  check_output "lib.$fn exists" '^true$' ev "let lib = $NIXPKGS.lib; in builtins.isFunction lib.$fn"
done
check_output "pkgs.nginxMainline exists" '^"nginx-' ev "(import $NIXPKGS { }).nginxMainline.name"

section "The module system"
note_block "$NOTE" "The module system" 1 >myapp.nix
sys() {
  echo "let s = (builtins.getFlake \"path:/repo/tests/nixos\").lib.system { container = false; module = {
    imports = [ $PWD/myapp.nix ];
    nixpkgs.overlays = [ (final: prev: { myapp = prev.hello; }) ];
    $1 }; }; in s.config"
}
nev() { nix eval --impure --json --expr "$(sys "$1").$2"; }
check_output "the module adds the unit when enabled" '/bin/myapp --port 8080' \
  nev 'services.myapp.enable = true;' systemd.services.myapp.serviceConfig.ExecStart
check_output "and opens the port" '\[8080\]' nev 'services.myapp.enable = true;' networking.firewall.allowedTCPPorts
check_output "and creates the system user" '^true$' nev 'services.myapp.enable = true;' users.users.myapp.isSystemUser
check_output "disabled, it adds nothing" '^false$' \
  nix eval --impure --json --expr "builtins.hasAttr \"myapp\" ($(sys '')).systemd.services"
check_output "types.port rejects 70000 at evaluation time" 'not of type.*16 bit unsigned integer' \
  bash -c "nix eval --impure --json --expr '$(sys 'services.myapp = { enable = true; port = 70000; };').networking.firewall.allowedTCPPorts' 2>&1; true"
# The correction: a plain `if` around config recurses; mkIf does not.
# Build the `if` variant explicitly: the last "  };" closes config.
awk '{ lines[NR] = $0 } END {
  for (i = NR; i > 0; i--) if (lines[i] == "  };") { last = i; break }
  for (i = 1; i <= NR; i++) {
    l = lines[i]
    sub(/config = mkIf cfg.enable \{/, "config = if cfg.enable then {", l)
    if (i == last) l = "  } else { };"
    print l
  } }' myapp.nix >if.nix
out=$(nix eval --impure --json --expr "$(sys 'services.myapp.enable = true;' | sed "s|$PWD/myapp.nix|$PWD/if.nix|").networking.firewall.allowedTCPPorts" 2>&1 || true)
assert_match "config = if cfg.enable ... gives infinite recursion" 'infinite recursion encountered' "$out"

section "Overriding packages"
check_output "nginx.override { withDebug = true; } (from the note)" '^"nginx-' \
  ev "let pkgs = import $NIXPKGS { }; in ($(note_block "$NOTE" "Overriding packages" 1 | sed -n '/override {/p' | sed 's/#.*//')).name"
check_output "overrideAttrs changes an attribute" '^false$' \
  ev "let pkgs = import $NIXPKGS { }; in (pkgs.hello.overrideAttrs (old: { doCheck = false; })).doCheck"

section "Debugging"
check_output "builtins.trace prints the message" 'trace: value is 5' \
  bash -c "nix-instantiate --eval --expr 'let x = 5; in $(note_block "$NOTE" Debugging 2 | sed -n 1p | sed 's/#.*//')' 2>&1"
check_output "lib.debug.traceVal prints the value" 'trace: 7' \
  bash -c "nix-instantiate --eval --expr 'let lib = $NIXPKGS.lib; someExpression = 7; in $(note_block "$NOTE" Debugging 2 | sed -n 2p)' 2>&1"
