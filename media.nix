{ lib, ... }:

let
  mediaPath = "/myraid1/nas/films";
  qbittorrentProfile = "/var/lib/qBittorrent";
  qbittorrentConfig = "${qbittorrentProfile}/qBittorrent/config/qBittorrent.conf";
in
{
  # Shared group: qBittorrent writes the files and Jellyfin reads them.
  users.groups.media = { };

  # Manual torrent search / indexer management.
  # Configure the SOCKS5 indexer proxy in the Prowlarr UI as 127.0.0.1:1080.
  services.prowlarr = {
    enable = true;
    openFirewall = true;
    settings = {
      server.bindaddress = "*";
      log.analyticsEnabled = false;
    };
  };

  # Torrent downloads stay on the normal host network.  The AmneziaWG module
  # deliberately does not install a default VPN route, so peer traffic is not
  # sent through the VPN.
  services.qbittorrent = {
    enable = true;
    group = "media";
    profileDir = qbittorrentProfile;
    webuiPort = 8080;
    torrentingPort = 49160;
    openFirewall = true;
  };

  # Seed only the first qBittorrent configuration.  Later changes made in the
  # Web UI (including the password) remain persistent across rebuilds.
  systemd.services.qbittorrent = {
    unitConfig.RequiresMountsFor = [ mediaPath ];
    preStart = lib.mkBefore ''
      if [ ! -e ${lib.escapeShellArg qbittorrentConfig} ]; then
        umask 077
        mkdir -p "$(dirname ${lib.escapeShellArg qbittorrentConfig})"
        cat > ${lib.escapeShellArg qbittorrentConfig} <<'EOF'
[LegalNotice]
Accepted=true

[Preferences]
BitTorrent\Session\QueueingSystemEnabled=false
Connection\PortRangeMin=49160
Downloads\SavePath=/myraid1/nas/films/
WebUI\Address=*
WebUI\AuthSubnetWhitelist=127.0.0.1/32
WebUI\AuthSubnetWhitelistEnabled=true
WebUI\LocalHostAuth=false
WebUI\Port=8080
EOF
      fi
    '';
  };

  # Jellyfin replaces MiniDLNA.  Since Jellyfin 10.9 DLNA is an official
  # plugin, so install "DLNA" once from Dashboard -> Plugins -> Catalog.
  services.jellyfin = {
    enable = true;
    group = "media";
    openFirewall = true;
  };

  systemd.services.jellyfin.unitConfig.RequiresMountsFor = [ mediaPath ];

  # qBittorrent owns the download directory; the setgid bit keeps new
  # directories in the shared media group.
  systemd.tmpfiles.rules = [
    "d ${mediaPath} 2775 qbittorrent media -"
  ];

  # qBittorrent's NixOS module opens its configured ports over TCP.  DHT/uTP
  # also need the torrent port over UDP.
  networking.firewall.allowedUDPPorts = [ 49160 ];
}
