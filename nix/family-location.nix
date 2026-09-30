{ pkgs, ... }:

let
  familyLocationPort = 8085;
  python = pkgs.python3.withPackages (ps: with ps; [ websockets ]);
  familyLocationApp = ./family-location.py;
in
{
  users.groups.family-location = { };
  users.users.family-location = {
    isSystemUser = true;
    group = "family-location";
  };

  # Credentials and the friend allow-list are deliberately runtime-only so
  # account data and names never enter the public NixOS repository.
  systemd.tmpfiles.rules = [
    "d /var/lib/family-location 0700 root root - -"
  ];

  systemd.services.family-location = {
    description = "Private 2GIS location feed for family.home";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "simple";
      User = "family-location";
      Group = "family-location";
      EnvironmentFile = "-/var/lib/family-location/credentials.env";
      Environment = "FAMILY_LOCATION_PORT=${toString familyLocationPort}";
      ExecStart = "${python}/bin/python ${familyLocationApp}";
      Restart = "on-failure";
      RestartSec = 5;

      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
    };
  };

  systemd.services.homepage-dashboard = {
    wants = [ "family-location.service" ];
    after = [ "family-location.service" ];
  };
}
