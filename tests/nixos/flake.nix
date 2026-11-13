# NixOS systems for the note tests. scripts/nixos-image.sh builds one from a test's
# module and imports it into Docker, where it boots with systemd as PID 1.
# The nixpkgs pin lives in flake.lock. Update it with `make nixos-update`.
{
  description = "NixOS systems for the note tests";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { nixpkgs, ... }: {
    lib = rec {
      # system: the NixOS configuration for MODULE (a path, or null for the base only).
      # NOTE (e.g. "linux/distributions/nixos/hardening") gives the module a `notes`
      # argument: notes.module "Heading" 1 is that code block, as a module. See notes.nix.
      # Tests evaluate options with it: (lib.system { ... }).config.<option>
      # container = false evaluates it as a normal host instead (host.nix), without the
      # Docker profile. Such a system is for evaluation only.
      system = { module ? null, note ? null, container ? true, root ? "/repo", system ? builtins.currentSystem }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs.nixpkgsSource = nixpkgs.outPath;
          specialArgs.notes =
            if note == null then null
            else import ./notes.nix { inherit (nixpkgs) lib; file = /. + "${root}/content/${note}.md"; };
          modules = [ ./base.nix (if container then ./container.nix else ./host.nix) ]
            ++ nixpkgs.lib.optional (module != null) module;
        };

      # tarball: the root filesystem that `docker import` turns into an image.
      tarball = args: (system { inherit (args) module note; }).config.system.build.tarball;

      # vmTest: a NixOS VM test (runNixOSTest) from TEST, a path to a test module
      # ({ name; nodes; testScript; }). Its nodes get the same `notes` argument.
      # Building it runs the test, in QEMU. See tests/lib/nixos-vm.sh.
      vmTest = { test, note ? null, root ? "/repo", system ? builtins.currentSystem }:
        nixpkgs.legacyPackages.${system}.testers.runNixOSTest {
          imports = [ test ];
          node.specialArgs.notes =
            if note == null then null
            else import ./notes.nix { inherit (nixpkgs) lib; file = /. + "${root}/content/${note}.md"; };
        };
    };
  };
}
