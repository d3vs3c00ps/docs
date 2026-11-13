# For the NixOS notes that run with the nix CLI alone (language, derivations, flakes).
FROM nixos/nix:2.35.2
RUN mkdir -p /etc/nix && echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf
# The image has grep and coreutils, but tests/lib needs awk, sed and cmp too. Same
# nixpkgs revision as tests/nixos/flake.lock, so the store shares the packages.
RUN nix profile add \
      github:NixOS/nixpkgs/f5c082a40f7571c266e74e80ae2e68aadd8a9fc7#gawk \
      github:NixOS/nixpkgs/f5c082a40f7571c266e74e80ae2e68aadd8a9fc7#gnused \
      github:NixOS/nixpkgs/f5c082a40f7571c266e74e80ae2e68aadd8a9fc7#diffutils \
    && nix-collect-garbage >/dev/null
WORKDIR /work
