{ ... }:

let
  nasPath = "/myraid1/nas";
in
{
  # SMB share for mapping the NAS as a Windows network drive
  # (\\nixos.home\nas). Only the account in "valid users" can connect; its
  # Samba password is set once on the host with smbpasswd and never stored
  # in Git. See SAMBA.md.
  services.samba = {
    enable = true;
    # 139/445 TCP for SMB, 137/138 UDP for NetBIOS names (\\nixos).
    openFirewall = true;

    settings = {
      # The firewall opens SMB on every interface, including awg0, wg-home
      # and the AI namespace veth, so Samba itself accepts only private LAN
      # clients. Loopback is always allowed.
      global."hosts allow" = "192.168.0.0/16";

      nas = {
        path = nasPath;
        "valid users" = "sergey";
        "read only" = "no";
        # Group-writable results keep files added to the setgid media
        # directory usable by qBittorrent and Jellyfin.
        "create mask" = "0664";
        "directory mask" = "0775";
      };
    };
  };

  # Write access to qBittorrent's media-owned download directory over SMB.
  users.users.sergey.extraGroups = [ "media" ];

  systemd.services.samba-smbd.unitConfig.RequiresMountsFor = [ nasPath ];
}
