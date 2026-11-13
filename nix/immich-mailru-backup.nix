{ config, pkgs, ... }:

let
  # This is the Immich-managed media directory, NOT a folder for manual
  # uploads. It must be backed up together with the PostgreSQL database.
  mediaPath = "/myraid1/nas/Photos";
  mountPath = "/myraid1";
  secretsDir = "/etc/immich-mailru";
  stagingDir = "/var/lib/immich-mailru-backup";
  databaseDump = "${stagingDir}/immich.pgcustom";
in
{
  # rclone's official WebDAV backend talks to Mail.ru Cloud using an
  # application-specific password. Restic encrypts backups on the client,
  # and keeps point-in-time snapshots rather than mirroring deletions.
  # No credentials or encryption passwords are committed to the Nix store.
  services.restic.backups.immich-mailru = {
    repository = "rclone:mailru:ImmichBackups/restic";
    passwordFile = "${secretsDir}/restic-password";
    rcloneConfigFile = "${secretsDir}/rclone.conf";
    # Applied to both the timer and the generated restic CLI wrapper.
    # The password command is only needed for an encrypted rclone config.
    rcloneOptions = {
      ask_password = "false";
      password_command = "${pkgs.coreutils}/bin/cat ${secretsDir}/rclone-config-password";
    };
    initialize = true;

    paths = [ mediaPath databaseDump ];

    # Generated previews and transcoded videos can be regenerated from
    # originals. Exclude the contents, NOT the parent directories, and
    # preserve the .immich mount integrity markers for recovery.
    # Keep all originals, profile images, sidecars, and database dumps.
    exclude = [
      "${mediaPath}/thumbs/*"
      "!${mediaPath}/thumbs/.immich"
      "${mediaPath}/encoded-video/*"
      "!${mediaPath}/encoded-video/.immich"
    ];

    backupPrepareCommand = ''
      #!${pkgs.runtimeShell}
      set -euo pipefail
      umask 077
      if ! ${pkgs.util-linux}/bin/mountpoint -q ${mountPath}; then
        echo "Refusing Immich backup: the ZFS pool is not mounted" >&2
        exit 1
      fi
      if [ ! -d "${mediaPath}" ]; then
        echo "Refusing Immich backup: the media directory is missing" >&2
        exit 1
      fi
      ${pkgs.coreutils}/bin/install -d -m 0700 -o root -g root "${stagingDir}"
      tmp="$(${pkgs.coreutils}/bin/mktemp "${stagingDir}/immich.XXXXXXXX")"
      trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT

      # Logical, consistent dump while PostgreSQL is running; no raw live
      # PostgreSQL data-directory copies.
      ${pkgs.util-linux}/bin/runuser -u postgres -- \
        ${config.services.postgresql.package}/bin/pg_dump \
        --format=custom --dbname=${config.services.immich.database.name} > "$tmp"

      ${pkgs.coreutils}/bin/mv -f "$tmp" "${databaseDump}"
    '';

    backupCleanupCommand = ''
      #!${pkgs.runtimeShell}
      set -eu
      ${pkgs.coreutils}/bin/rm -f "${databaseDump}"
    '';

    timerConfig = {
      OnCalendar = "*-*-* 03:30:00";
      Persistent = true;
      RandomizedDelaySec = "30min";
    };

    # Retain restore points for accidental deletion or corruption. Pruning
    # affects ONLY the separate encrypted Restic repository in Mail.ru,
    # never the original cloud folders or Immich's local media.
    pruneOpts = [
      "--keep-daily 14"
      "--keep-weekly 8"
      "--keep-monthly 12"
    ];
  };

  systemd.services.restic-backups-immich-mailru = {
    # The unit is intentionally skipped until the administrator provisions
    # BOTH local secret files. Missing secrets never block Immich startup.
    unitConfig = {
      ConditionPathExists = [
        "${secretsDir}/rclone.conf"
        "${secretsDir}/restic-password"
      ];
      RequiresMountsFor = [ mountPath ];
    };
    requires = [ "immich-storage.service" "postgresql.service" ];
    after = [ "immich-storage.service" "postgresql.service" ];
    path = [ pkgs.rclone ];
    # Only mark a completely successful backup/prune run, never a mere start.
    serviceConfig.ExecStartPost = [
      "${pkgs.coreutils}/bin/touch ${stagingDir}/last-success"
    ];
  };

  # Allow setting up the private WebDAV remote without a one-off Nix shell.
  environment.systemPackages = [ pkgs.rclone ];
}
