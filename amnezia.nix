{ pkgs, ... }:

let
  configFile = "/etc/amnezia/amneziawg/awg0.conf";
in
{
  # Нужен userspace-клиенту для создания VPN-интерфейса.
  boot.kernelModules = [ "tun" ];

  environment.systemPackages = with pkgs; [
    amneziawg-tools
    amneziawg-go
  ];

  systemd.tmpfiles.rules = [
    "d /etc/amnezia/amneziawg 0700 root root -"
  ];

  systemd.services.amneziawg = {
    description = "AmneziaWG userspace tunnel";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    unitConfig.ConditionPathExists = configFile;

    environment = {
      WG_ENDPOINT_RESOLUTION_RETRIES = "infinity";
      WG_QUICK_USERSPACE_IMPLEMENTATION =
        "${pkgs.amneziawg-go}/bin/amneziawg-go";
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart =
        "${pkgs.amneziawg-tools}/bin/awg-quick up ${configFile}";
      ExecStop =
        "${pkgs.amneziawg-tools}/bin/awg-quick down ${configFile}";
    };
  };
}
