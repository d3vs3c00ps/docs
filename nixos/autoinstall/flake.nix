# A NixOS installer ISO that installs a fixed system with no questions, like a
# Kickstart or preseed install. Build and test it with scripts/nixos-iso.sh.
# See content/linux/distributions/nixos/automated-install.md.
{
  description = "Unattended NixOS installer ISO";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, disko, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forSystem = system: rec {
        # The system that ends up on the disk.
        target = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [ disko.nixosModules.disko ./disk.nix ./target.nix ];
        };
        # The ISO that installs it.
        installer = nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit target; };
          modules = [ ./installer.nix ];
        };
      };
    in
    {
      packages = nixpkgs.lib.genAttrs systems (system: {
        iso = (forSystem system).installer.config.system.build.isoImage;
        default = (forSystem system).installer.config.system.build.isoImage;
      });
      nixosConfigurations = nixpkgs.lib.listToAttrs (map (system: {
        name = "target-${system}";
        value = (forSystem system).target;
      }) systems);
    };
}
