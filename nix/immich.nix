{ inputs, pkgs, ... }:

let
  zfsMount = "/myraid1";
  photoStorage = "${zfsMount}/nas/Photos";
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

  # Store photos in the NAS tree, but keep the managed library inaccessible
  # through Samba (immich:immich, mode 0700).
  # Never adopt a pre-existing populated folder owned by another user:
  # photos must instead be migrated through Immich's import tools.
  #
  # Fail closed if ZFS is not mounted; do not create the folder on root disk.
  systemd.services.immich-storage = {
    description = "Prepare private Immich storage on ZFS";
    after = [ "zfs-mount.service" ];
    unitConfig.RequiresMountsFor = [ zfsMount "${zfsMount}/nas" ];
    serviceConfig.Type = "oneshot";
    script = ''
      if ! ${pkgs.util-linux}/bin/mountpoint -q ${zfsMount}; then
        echo "Immich storage unavailable: ${zfsMount} is not mounted" >&2
        exit 1
      fi
      if [ ! -d "${zfsMount}/nas" ]; then
        echo "Immich storage unavailable: NAS directory is missing" >&2
        exit 1
      fi
      if [ -L "${photoStorage}" ]; then
        echo "Immich storage cannot be a symbolic link" >&2
        exit 1
      fi
      if [ -e "${photoStorage}" ]; then
        if [ ! -d "${photoStorage}" ]; then
          echo "Immich storage exists but is not a directory" >&2
          exit 1
        fi
        # Adopt an empty directory, but never silently take ownership
        # of an existing populated collection.
        if [ -n "$(${pkgs.findutils}/bin/find "${photoStorage}" -mindepth 1 -maxdepth 1 -print -quit)" ] \
          && [ "$(${pkgs.coreutils}/bin/stat -c '%U:%G' "${photoStorage}")" != "immich:immich" ]; then
          echo "Immich storage contains files not owned by Immich; import them manually" >&2
          exit 1
        fi
      fi
      ${pkgs.coreutils}/bin/install -d -m 0700 -o immich -g immich "${photoStorage}"
    '';
  };

  systemd.services.immich-server = {
    requires = [ "immich-storage.service" ];
    after = [ "immich-storage.service" ];
    unitConfig.RequiresMountsFor = [ zfsMount "${zfsMount}/nas" ];
  };
}
