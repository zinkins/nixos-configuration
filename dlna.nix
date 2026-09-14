{ ... }:

let
  # ZFS pool mount point. Change this if the video dataset is mounted elsewhere.
  mediaPath = "/myraid1";
in
{
  services.minidlna = {
    enable = true;
    openFirewall = true;

    settings = {
      friendly_name = "NixOS Media";
      media_dir = [ "V,${mediaPath}" ];
      inotify = "yes";
      enable_subtitles = "yes";
    };
  };

  # Start the media scanner only after ZFS datasets have been mounted.
  systemd.services.minidlna = {
    after = [ "zfs-mount.service" ];
    wants = [ "zfs-mount.service" ];
  };
}
