{ inputs, pkgs, ... }:

let
  zfsMount = "/myraid1";
  photoStorage = "${zfsMount}/immich";
in
{
  # Separate accounts, mobile uploads and shared albums. The NixOS Immich
  # module provisions its PostgreSQL and Redis dependencies automatically.
  # Only Caddy can reach the backend; no direct LAN/WAN port is opened.
  services.immich = {
    enable = true;
    # Stable NixOS 26.05 packages Immich 2.7.5, which is marked insecure.
    # Use a separately locked nixpkgs 3.x package, never permitInsecurePackages.
    package = inputs.immich-nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}.immich;
    host = "127.0.0.1";
    port = 2283;
    openFirewall = false;
    mediaLocation = photoStorage;
  };

  # The media directory is intentionally outside /myraid1/nas (the Samba
  # share), so private photos are not exposed through the NAS share.
  #
  # A normal tmpfiles "d" rule can create a directory on the root filesystem
  # before ZFS is mounted. Fail closed instead: prepare the folder as root
  # only after verifying that the pool is actually mounted.
  systemd.services.immich-storage = {
    description = "Prepare private Immich storage on ZFS";
    after = [ "zfs-mount.service" ];
    unitConfig.RequiresMountsFor = [ zfsMount ];
    serviceConfig.Type = "oneshot";
    script = ''
      if ! ${pkgs.util-linux}/bin/mountpoint -q ${zfsMount}; then
        echo "Immich storage unavailable: ${zfsMount} is not mounted" >&2
        exit 1
      fi
      ${pkgs.coreutils}/bin/install -d -m 0700 -o immich -g immich ${photoStorage}
    '';
  };

  systemd.services.immich-server = {
    requires = [ "immich-storage.service" ];
    after = [ "immich-storage.service" ];
    unitConfig.RequiresMountsFor = [ zfsMount ];
  };
}
