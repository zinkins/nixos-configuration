{ config, pkgs, ... }:
let
  tools = pkgs.writeShellApplication {
    name = "immich-setup";
    runtimeInputs = [ pkgs.python3 pkgs.rclone pkgs.systemd pkgs.util-linux pkgs.coreutils pkgs.dnsutils config.services.fail2ban.package ];
    text = ''
      exec python3 ${./scripts/immich-operator.py} setup "$@"
    '';
  };
  doctor = pkgs.writeShellApplication {
    name = "immich-doctor";
    runtimeInputs = [ pkgs.python3 pkgs.rclone pkgs.systemd pkgs.util-linux pkgs.coreutils pkgs.dnsutils config.services.fail2ban.package ];
    text = ''
      exec python3 ${./scripts/immich-operator.py} doctor "$@"
    '';
  };
in
{
  environment.systemPackages = [ tools doctor ];
  systemd.tmpfiles.rules = [
    "d /var/lib/immich-operator 0700 root root -"
    "d /run/immich-health 0755 root root -"
  ];
  systemd.services.immich-doctor = {
    description = "Collect privacy-safe Immich health status";
    after = [ "immich-server.service" "caddy.service" "fail2ban.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${doctor}/bin/immich-doctor";
      UMask = "0077";
      TimeoutStartSec = "120s";
    };
  };
  systemd.timers.immich-doctor = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnCalendar = "*-*-* *:0/5:00";
      Persistent = true;
    };
  };
  system.extraDependencies = [
    (pkgs.runCommand "immich-operator-test" { nativeBuildInputs = [ pkgs.python3 ]; } ''
      python3 -m py_compile ${./scripts/immich-operator.py}
      python3 ${./scripts/immich-operator.py} self-test
      touch "$out"
    '')
  ];
}
