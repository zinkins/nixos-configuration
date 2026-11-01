{ pkgs, inputs, ... }:

let
  herdr = inputs.herdr-nix.packages.${pkgs.stdenv.hostPlatform.system}.herdr;
  python = pkgs.python3.withPackages (ps: [ ps.tomlkit ]);
  configEditor = ./herdr-settings.py;
  dailyRefresh = pkgs.writeShellScript "herdr-refresh-manifests" ''
    set -euo pipefail

    # An hourly local check avoids missing updates for users who normally run
    # Herdr only during the day. It must not imply hourly network requests.
    if ! ${pkgs.procps}/bin/pgrep -u "$(${pkgs.coreutils}/bin/id -u)" -x herdr >/dev/null; then
      echo "Herdr is not running; skipping manifest update."
      exit 0
    fi

    state_dir="$HOME/.local/state/herdr"
    stamp="$state_dir/last-scheduled-manifest-refresh"
    now="$(${pkgs.coreutils}/bin/date +%s)"
    if [ -r "$stamp" ]; then
      last="$(${pkgs.coreutils}/bin/cat "$stamp")"
      if [[ "$last" =~ ^[0-9]+$ ]] && (( now >= last && now - last < 86400 )); then
        echo "Herdr manifests were checked less than 24 hours ago; skipping."
        exit 0
      fi
    fi

    ${herdr}/bin/herdr server update-agent-manifests
    ${pkgs.coreutils}/bin/mkdir -p "$state_dir"
    printf '%s\n' "$now" > "$stamp"
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
      # No network request unless Herdr is running and 24h have passed since
      # the previous successful scheduled refresh.
      OnCalendar = "hourly";
      Persistent = true;
      RandomizedDelaySec = "10min";
      Unit = "herdr-manifest-refresh.service";
    };
  };
}
