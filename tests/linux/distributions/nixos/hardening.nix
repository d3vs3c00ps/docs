# The system hardening.sh boots: the note's blocks that are safe in a container.
# The kernel, AppArmor and audit blocks would change the shared host kernel, so the
# test only evaluates those (nixos_eval --host).
{ notes, lib, pkgs, ... }:
{
  imports = [
    (notes.module "SSH and access" 1)
    (notes.module "systemd sandboxing" 1)
    (notes.module "Firewall" 1)
    (notes.module "Automatic updates" 1)
  ];

  # The container profile turns the firewall off; the note turns it on.
  networking.firewall.enable = lib.mkForce true;

  # A service for the sandboxing block to confine, with a token where the note says
  # it leaks.
  systemd.services.myapp = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server -d /var/lib/myapp 8080";
    serviceConfig.Environment = "TOKEN=s3cret-token";
  };
}
