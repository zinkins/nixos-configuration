{ config, ... }:

let
  gateDir = "/etc/immich-remote";
  loginLog = "/var/log/caddy/immich-login.log";
in
{
  # Trusted HTTPS for the official mobile apps, enabled only after local setup.
  services.caddy.virtualHosts."immich.zinkin.me" = {
    logFormat = ''
      output file ${loginLog} {
        mode 0600
        roll_size 10MiB
        roll_keep 3
      }
      format json
    '';
    extraConfig = ''
      @notLogin not path /api/auth/login
      log_skip @notLogin

      # Initial administrator registration always stays local.
      @setup path /api/auth/admin-sign-up /api/auth/admin-sign-up/*
      @enabled file {
        root ${gateDir}
        try_files /enabled
      }

      route {
        respond @setup 403
        handle @enabled {
          header Strict-Transport-Security "max-age=31536000"
          # Stream large uploads and WebSockets; no request size cap.
          reverse_proxy 127.0.0.1:2283 {
            header_up X-Real-IP {http.request.remote.host}
          }
        }
        handle {
          respond "Immich remote access has not been enabled." 503
        }
      }
    '';
  };

  # Caddy cannot write the activation marker. The log exists before Fail2ban starts.
  systemd.tmpfiles.rules = [
    "d ${gateDir} 0755 root root -"
    "d /var/log/caddy 0750 ${config.services.caddy.user} ${config.services.caddy.group} -"
    "f ${loginLog} 0600 ${config.services.caddy.user} ${config.services.caddy.group} -"
  ];

  # Match failed password logins, not expired sessions or media traffic.
  # Use the actual TCP peer rather than a spoofable forwarded IP header.
  services.fail2ban = {
    enable = true;
    jails.sshd.enabled = false;
    jails.immich-login = {
      enabled = true;
      filter.Definition = {
        failregex = ''^\{.*?"request":\{"remote_ip":"<ADDR>".*?"method":"POST".*?"uri":"/api/auth/login(?:\?[^"]*)?".*?"status":401[,}]'';
        datepattern = ''"ts":{EPOCH}'';
      };
      settings = {
        backend = "auto";
        logpath = loginLog;
        port = "443";
        maxretry = 10;
        findtime = "10m";
        bantime = "30m";
        usedns = "no";
      };
    };
  };

  systemd.services.fail2ban.after = [ "caddy.service" ];
}
