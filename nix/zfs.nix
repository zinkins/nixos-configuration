{ ... }:

{
  # Limit snapshots to the NAS dataset and its children, not the pool root
  # (which also contains the regenerable cloud archive cache).
  services.sanoid = {
    enable = true;
    interval = "hourly";
    datasets."myraid1/nas" = {
      recursive = true;
      frequently = 0;
      hourly = 0;
      daily = 7;
      weekly = 4;
      monthly = 3;
      yearly = 0;
      autosnap = true;
      autoprune = true;
    };

    # Only effective if films is a separate dataset. Use settings rather
    # than datasets so the NixOS service does not delegate ZFS permissions
    # on a potentially nonexistent dataset.
    settings."myraid1/nas/films" = {
      autosnap = false;
      autoprune = false;
      monitor = false;
      skip_children = true;
    };
  };

  systemd.services.sanoid = {
    after = [ "zfs-mount.service" ];
    unitConfig.ConditionPathIsMountPoint = "/myraid1/nas";
  };
  systemd.timers.sanoid.timerConfig.Persistent = true;
}
