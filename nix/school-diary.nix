{ pkgs, ... }:

{
  systemd.services.school-diary = {
    description = "Local school diary cache for family.home";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.python3}/bin/python ${./school-diary/server.py} ${./school-diary/bookmarklet.js}";
      Restart = "on-failure";
      RestartSec = 2;
      DynamicUser = true;
      StateDirectory = "school-diary";
      UMask = "0077";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_INET" ];
    };
  };

  systemd.services.homepage-dashboard = {
    wants = [ "school-diary.service" ];
    after = [ "school-diary.service" ];
  };
}
