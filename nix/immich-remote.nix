{ config, pkgs, ... }:

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
      # Match the normalized path, including case and trailing-slash variants.
      @notLogin not path /api/auth/login*
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
        # Only the login route is written to this dedicated log; do not
        # depend on the unnormalized URI spelling in the JSON log record.
        failregex = ''^\{.*?"request":\{"remote_ip":"<ADDR>".*?"method":"POST".*?"status":401[,}]'';
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

  # NixOS's Caddy module formats the generated file but does not adapt it
  # at build time. Require both syntax adaptation and a real Fail2ban
  # regression test before the system closure can be built/deployed.
  system.extraDependencies = [
    (pkgs.runCommand "immich-remote-config-check" {
      nativeBuildInputs = [ config.services.caddy.package config.services.fail2ban.package ];
    } ''
      caddy adapt --adapter caddyfile --config ${config.services.caddy.configFile} > "$TMPDIR/caddy.json"
      cat > "$TMPDIR/login.log" <<'EOF'
      {"level":"info","ts":1794400000.123,"request":{"remote_ip":"192.0.2.1","method":"POST","uri":"/api/auth/login/"},"status":401}
      {"level":"info","ts":1794400000.124,"request":{"remote_ip":"192.0.2.2","method":"POST","uri":"/api/auth/login"},"status":200}
      {"level":"info","ts":1794400000.125,"request":{"remote_ip":"192.0.2.3","method":"GET","uri":"/api/auth/login"},"status":401}
      EOF
      fail2ban-regex "$TMPDIR/login.log" ${config.environment.etc."fail2ban/filter.d/immich-login.conf".source} > "$TMPDIR/result"
      cat "$TMPDIR/result"
      grep -F '1 matched, 2 missed' "$TMPDIR/result"
      touch "$out"
    '')
  ];
}

