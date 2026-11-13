#!/usr/bin/env bash
# note: linux/distributions/nixos/sops.md
# env: nix
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"

# The nixpkgs of tests/nixos/flake.lock, already in the notes-nix-store volume.
tools() { nix shell --inputs-from path:/repo/tests/nixos nixpkgs#sops nixpkgs#age nixpkgs#ssh-to-age nixpkgs#openssh -c "$@"; }
# as KEY CMD...: run a tool with another age identity.
as() { local k=$1; shift; SOPS_AGE_KEY_FILE=$PWD/$k.age tools "$@"; }
cd "$(mktemp -d)"
mkdir secrets

section "Keys"
ssh-keygen() { tools ssh-keygen "$@"; }
ssh-keygen -q -t ed25519 -N '' -f admin
ssh-keygen -q -t ed25519 -N '' -f host
admin=$(tools ssh-to-age < admin.pub)
host=$(tools ssh-to-age < host.pub)
check_output "ssh-to-age turns an Ed25519 public key into an age recipient" '^age1' echo "$admin"
tools ssh-to-age -private-key -i admin > admin.age

section ".sops.yaml"
cat > .sops.yaml <<YAML
creation_rules:
  - path_regex: secrets/web-01\.yaml$
    key_groups:
      - age: ["$admin", "$host"]
YAML
printf 'db:\n  password: hunter2\n' > secrets/web-01.yaml
export SOPS_AGE_KEY_FILE=$PWD/admin.age
tools sops -e -i secrets/web-01.yaml
check_output "keys stay readable" '^db:' cat secrets/web-01.yaml
check_output "values are encrypted" 'password: ENC\[AES256_GCM' cat secrets/web-01.yaml
check_output "the admin decrypts the nested key" '^hunter2$' tools sops -d --extract '["db"]["password"]' secrets/web-01.yaml

section "Deep dive"
# The host decrypts with a key derived from its SSH host key, as sops-nix does.
tools ssh-to-age -private-key -i host > host.age
check_output "the host key decrypts too" '^hunter2$' as host sops -d --extract '["db"]["password"]' secrets/web-01.yaml

# Rekeying: add a second admin, drop the first one.
ssh-keygen -q -t ed25519 -N '' -f admin2
admin2=$(tools ssh-to-age < admin2.pub)
tools ssh-to-age -private-key -i admin2 > admin2.age
cp secrets/web-01.yaml before.yaml
sed -i "s/\"$admin\"/\"$admin\", \"$admin2\"/" .sops.yaml
tools sops updatekeys -y secrets/web-01.yaml
check_output "updatekeys adds a recipient: the new admin decrypts" '^hunter2$' as admin2 sops -d --extract '["db"]["password"]' secrets/web-01.yaml
sed -i "s/\"$admin\", //" .sops.yaml
tools sops updatekeys -y secrets/web-01.yaml
check_fails "a removed recipient cannot decrypt the new file" tools sops -d secrets/web-01.yaml
check_output "but still decrypts the copy it had before (rotate the values)" '^hunter2$' tools sops -d --extract '["db"]["password"]' before.yaml
