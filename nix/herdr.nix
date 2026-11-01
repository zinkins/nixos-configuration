{ pkgs, inputs, ... }:

let
  herdr = inputs.herdr-nix.packages.${pkgs.stdenv.hostPlatform.system}.herdr;
  python = pkgs.python3.withPackages (ps: [ ps.tomlkit ]);
  configEditor = ./herdr-settings.py;
  dailyRefresh = pkgs.writeShellScript "herdr-refresh-manifests" ''
    # Don't contact herdr.dev when no Herdr instance is running for this user.
    if ! ${pkgs.procps}/bin/pgrep -u "$(${pkgs.coreutils}/bin/id -u)" -x herdr >/dev/null; then
      echo "Herdr is not running; skipping manifest update."
      exit 0
    fi

    exec ${herdr}/bin/herdr server update-agent-manifests
  '';
in
{
  # Herdr's default startup and 30-minute checks are separate from the Nix
  # package version. Manage both through the user's existing config.toml while
  # preserving all unrelated settings and avoiding a global config override.
  systemd.user.services.herdr-background-settings = {
    description = "Configure Herdr background updates without overwriting user preferences";
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${python}/bin/python ${configEditor} ${herdr}/bin/herdr";
    };
  };

  # A single daily request batch for up-to-date agent detection rules.
  # The built-in checks are disabled independently by the settings service.
  systemd.user.services.herdr-manifest-refresh = {
    description = "Refresh Herdr agent-detection manifests daily";
    wants = [ "herdr-background-settings.service" ];
    after = [ "herdr-background-settings.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = dailyRefresh;
    };
  };

  systemd.user.timers.herdr-manifest-refresh = {
    description = "Daily Herdr agent-detection manifest refresh";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "15min";
      Unit = "herdr-manifest-refresh.service";
    };
  };
}
