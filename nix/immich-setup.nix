{ config, lib, pkgs, ... }:
let
  tools = pkgs.writeShellApplication {
    name = "immich-setup";
    runtimeInputs = [ config.services.postgresql.package pkgs.python3 pkgs.rclone pkgs.systemd pkgs.util-linux pkgs.coreutils pkgs.dnsutils config.services.fail2ban.package ];
    text = ''
      export IMMICH_OPERATOR_DB=${lib.escapeShellArg config.services.immich.database.name}
      export IMMICH_OPERATOR_PSQL=${config.services.postgresql.package}/bin/psql
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
    (pkgs.runCommand "immich-operator-test" { nativeBuildInputs = [ pkgs.python3 pkgs.rclone pkgs.coreutils ]; } ''
      cp ${./scripts/immich-operator.py} "$TMPDIR/immich-operator.py"
      python3 -m py_compile "$TMPDIR/immich-operator.py"
      python3 ${./scripts/immich-operator.py} self-test
      cp ${./scripts/test-immich-cloud.py} "$TMPDIR/test-immich-cloud.py"
      python3 "$TMPDIR/test-immich-cloud.py"
      cp ${./scripts/test-immich-resume.py} "$TMPDIR/test-immich-resume.py"
      python3 "$TMPDIR/test-immich-resume.py"
      touch "$out"
    '')
  ];
}
