# /etc/nixos/amnezia.nix
{ config, pkgs, ... }:

let
  vpnConfig = "/etc/amnezia/amneziawg/awg0.conf";
in
{
  boot.extraModulePackages = [
    config.boot.kernelPackages.amneziawg
  ];

  boot.kernelModules = [ "amneziawg" ];

  environment.systemPackages = [
    pkgs.amneziawg-tools
  ];

  systemd.tmpfiles.rules = [
    "d /etc/amnezia/amneziawg 0700 root root -"
  ];

  systemd.services.amneziawg = {
    description = "AmneziaWG VPN";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    environment.WG_ENDPOINT_RESOLUTION_RETRIES = "infinity";

    unitConfig.ConditionPathExists = vpnConfig;

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart =
        "${pkgs.amneziawg-tools}/bin/awg-quick up ${vpnConfig}";
      ExecStop =
        "${pkgs.amneziawg-tools}/bin/awg-quick down ${vpnConfig}";
    };
  };
}