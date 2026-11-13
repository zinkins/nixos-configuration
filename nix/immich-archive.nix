{ config, pkgs, ... }:
let
  state = "/var/lib/immich-operator";
  cloud = "/etc/immich-mailru";
  mount = "/mnt/immich-family-archive";
  cache = "/myraid1/.immich-webdav-cache";
  cfg = config.services.immich;
  mountScript = pkgs.writeShellScript "immich-family-archive-mount" ''
    set -euo pipefail
    ${pkgs.util-linux}/bin/mountpoint -q /myraid1
    IFS= read -r remote < ${state}/archive-remote
    case "$remote" in mailru:?*) ;; *) exit 1 ;; esac
    if ${pkgs.util-linux}/bin/mountpoint -q ${mount}; then
      echo "Archive mountpoint is already occupied; refusing to replace it." >&2
      exit 1
    fi
    ${pkgs.coreutils}/bin/install -d -m 000 -o root -g root ${mount}
    if [ -n "$(${pkgs.findutils}/bin/find ${mount} -mindepth 1 -maxdepth 1 -print -quit)" ]; then
      echo "Archive mountpoint is not empty; refusing to hide existing files." >&2
      exit 1
    fi
    ${pkgs.coreutils}/bin/install -d -m 0700 -o root -g root ${cache}
    export RCLONE_ASK_PASSWORD=false
    export RCLONE_PASSWORD_COMMAND="${pkgs.coreutils}/bin/cat ${cloud}/rclone-config-password"
    exec ${pkgs.rclone}/bin/rclone mount "$remote" ${mount} \
      --config ${cloud}/rclone.conf --read-only \
      --allow-other --default-permissions \
      --uid "$(${pkgs.coreutils}/bin/id -u ${cfg.user})" \
      --gid "$(${pkgs.coreutils}/bin/id -g ${cfg.user})" \
      --umask 077 --dir-cache-time 5m \
      --vfs-cache-mode full --cache-dir ${cache} \
      --vfs-cache-max-size 20G --vfs-cache-max-age 24h \
      --vfs-cache-min-free-space 10G --vfs-cache-poll-interval 1m \
      --contimeout 15s --timeout 1m --log-level ERROR
  '';
in {
  # This mount is independent of managed Immich storage and the backup job.
  # A cloud outage must not prevent local phone uploads or Immich startup.
  systemd.services.immich-family-archive = {
    description = "Read-only Mail.ru family archive for Immich";
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.fuse3 ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "zfs-mount.service" ];
    unitConfig = {
      ConditionPathExists = [ "${state}/archive-remote" "${cloud}/rclone.conf" ];
      RequiresMountsFor = [ "/myraid1" ];
      StartLimitIntervalSec = 0;
    };
    serviceConfig = {
      Type = "notify";
      ExecStart = mountScript;
      ExecStop = "-${pkgs.fuse3}/bin/fusermount3 -u ${mount}";
      Restart = "on-failure";
      RestartSec = "30s";
      TimeoutStartSec = "90s";
      UMask = "0077";
    };
  };
}
