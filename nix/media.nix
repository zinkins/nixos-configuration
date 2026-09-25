{ lib, pkgs, ... }:

let
  mediaPath = "/myraid1/nas/films";
  qbittorrentProfile = "/var/lib/qBittorrent";
  qbittorrentConfig = "${qbittorrentProfile}/qBittorrent/config/qBittorrent.conf";
in
{
  # Shared group: qBittorrent writes the files and Jellyfin reads them.
  users.groups.media = { };

  # Intel N100 (Alder Lake-N) media stack for Jellyfin Quick Sync Video.
  # Direct Play remains preferred; QSV is used only when Jellyfin needs to
  # transcode video for a client.
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      vpl-gpu-rt
      intel-compute-runtime
    ];
  };

  users.users.jellyfin.extraGroups = [
    "render"
    "video"
  ];

  # Manual torrent search / indexer management.
  # LAN Web access is exposed through Caddy at http://prowlarr.home.
  # In Prowlarr, selected torrent indexers use the SOCKS5 proxy
  # 127.0.0.1:1080 (tag: vpn). Cloudflare-protected indexers can additionally
  # use Byparr/FlareSolverr (tag: cloudflare); see BYPARR.md.
  services.prowlarr = {
    enable = true;
    openFirewall = false;
    settings = {
      server.bindaddress = "*";
      log.analyticsEnabled = false;
    };
  };

  # Torrent downloads stay on the normal host network. The AmneziaWG module
  # deliberately does not install a default VPN route, so peer traffic is not
  # sent through the VPN.
  services.qbittorrent = {
    enable = true;
    group = "media";
    profileDir = qbittorrentProfile;
    webuiPort = 8080;
    torrentingPort = 49160;

    # Do not expose the Web UI port directly. The BitTorrent listen port is
    # opened explicitly below while the Web UI goes through Caddy.
    openFirewall = false;
  };

  # Seed only the first qBittorrent configuration. Later changes made in the
  # Web UI (including the password) remain persistent across rebuilds.
  systemd.services.qbittorrent = {
    unitConfig.RequiresMountsFor = [ mediaPath ];
    # Group-writable downloads, so media group members (the SMB user, see
    # samba.nix) can rename or delete them.
    serviceConfig.UMask = "0002";
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

  # Jellyfin replaces MiniDLNA. Since Jellyfin 10.9 DLNA is an official
  # plugin, install "DLNA" once from Dashboard -> Plugins -> Catalog.
  # Keep Jellyfin's own firewall opening enabled because DLNA clients fetch
  # media from Jellyfin directly; browser access can still use Caddy.
  services.jellyfin = {
    enable = true;
    group = "media";
    openFirewall = true;

    # Intel N100 exposes its Gen12 media engine through renderD128.
    hardwareAcceleration = {
      enable = true;
      type = "qsv";
      device = "/dev/dri/renderD128";
    };

    # Jellyfin has already been initialized on this host, so make the NixOS
    # transcoding configuration authoritative instead of leaving the existing
    # encoding.xml untouched.
    forceEncodingConfig = true;

    transcoding = {
      enableHardwareEncoding = true;
      enableIntelLowPowerEncoding = true;
      enableToneMapping = true;

      hardwareDecodingCodecs = {
        h264 = true;
        hevc = true;
        hevc10bit = true;
        mpeg2 = true;
        vp9 = true;
        av1 = true;
      };

      # Alder Lake-N can hardware-encode H.264 and HEVC; H.264 is always
      # enabled by the NixOS Jellyfin module, while AV1 encoding is not
      # supported by the N100 media engine.
      hardwareEncodingCodecs = {
        hevc = true;
        av1 = false;
      };
    };
  };

  systemd.services.jellyfin.unitConfig.RequiresMountsFor = [ mediaPath ];

  # qBittorrent owns the download directory; the setgid bit keeps new
  # directories in the shared media group.
  systemd.tmpfiles.rules = [
    "d ${mediaPath} 2775 qbittorrent media -"
  ];

  # qBittorrent Web UI (8080) stays behind the firewall/Caddy, while peer,
  # DHT and uTP traffic still needs the torrent port directly.
  networking.firewall.allowedTCPPorts = [ 49160 ];
  networking.firewall.allowedUDPPorts = [ 49160 ];
}
