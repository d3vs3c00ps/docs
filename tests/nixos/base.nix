# What every NixOS test system has: the tools the test helpers in tests/lib need.
# container.nix or host.nix is added to it, then the test's own module.
{ pkgs, ... }:
{
  system.stateVersion = "26.05";

  # Tests run as root. No login, no documentation.
  documentation.enable = false;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  environment.systemPackages = with pkgs; [
    bashInteractive coreutils findutils gnugrep gnused gawk diffutils which file less
    gnutar gzip xz curl git openssl jq procps iproute2 util-linux hostname python3
  ];
}
