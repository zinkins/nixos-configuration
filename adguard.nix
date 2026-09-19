{ lib, pkgs, ... }:

let
  localDomain = "home";
  dnsmasqRuntimeConfig = "/run/dnsmasq-home.conf";
in
{
  # DNS diagnostics used by the setup/troubleshooting documentation.
  environment.systemPackages = [ pkgs.dnsutils ];

  # dnsmasq is kept only as the authoritative resolver for the local .home
  # zone.  It no longer listens on LAN port 53; AdGuard Home is the only DNS
  # server exposed to clients.
  services.dnsmasq = {
    enable = true;
    resolveLocalQueries = false;
    settings = {
      port = 5353;
      listen-address = "127.0.0.1";
      bind-interfaces = true;
      conf-file = [ dnsmasqRuntimeConfig ];
      local = "/${localDomain}/";
      domain-needed = true;
      bogus-priv = true;
    };
  };

  systemd.services.dnsmasq = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    # Generate local DNS records from the interface carrying the IPv4 default
    # route so the LAN address does not have to be hard-coded in Git.
    preStart = lib.mkBefore ''
      lan_if="$(${pkgs.iproute2}/bin/ip -4 route show default | ${pkgs.gawk}/bin/awk '
        NR == 1 {
          for (i = 1; i <= NF; i++) {
            if ($i == "dev") {
              print $(i + 1)
              exit
            }
          }
        }
      ')"

      if [ -z "$lan_if" ]; then
        echo "Cannot determine LAN interface from the IPv4 default route" >&2
        exit 1
      fi

      cat > ${dnsmasqRuntimeConfig} <<EOF
interface-name=nixos.${localDomain},$lan_if/4
interface-name=family.${localDomain},$lan_if/4
interface-name=prowlarr.${localDomain},$lan_if/4
interface-name=qbittorrent.${localDomain},$lan_if/4
interface-name=jellyfin.${localDomain},$lan_if/4
interface-name=adguard.${localDomain},$lan_if/4
EOF
    '';
  };

  services.adguardhome = {
    enable = true;

    # The admin UI is reachable only through Caddy at http://adguard.home.
    host = "127.0.0.1";
    port = 3000;
    openFirewall = false;

    # Preserve UI settings that are not explicitly managed here while
    # re-applying this DNS/filtering baseline on every service restart.
    mutableSettings = true;

    settings = {
      # AdGuard Home stores only the BCrypt hash.  The plaintext password is
      # intentionally not committed to this public repository.
      users = [
        {
          name = "sergey";
          password = "$2y$12$B3TfpU8aUeB3Udpdpl05eO6ukFA9eruTsr25beYtnbl/U.DNcSGS2";
        }
      ];

      dns = {
        bind_hosts = [ "0.0.0.0" ];
        port = 53;

        # .home stays entirely local; all other DNS uses encrypted Quad9.
        upstream_dns = [
          "[/${localDomain}/]127.0.0.1:5353"
          "tls://dns.quad9.net"
        ];
        bootstrap_dns = [
          "9.9.9.9"
          "149.112.112.112"
        ];

        cache_enabled = true;
        cache_size = 16777216;
        edns_client_subnet = {
          enabled = false;
          use_custom = false;
          custom_ip = "";
        };
      };

      filtering = {
        protection_enabled = true;
        filtering_enabled = true;
        safebrowsing_enabled = true;
        parental_enabled = true;
        blocked_response_ttl = 10;

        safe_search = {
          enabled = true;
          bing = true;
          duckduckgo = true;
          google = true;
          pixabay = true;
          yandex = true;
          youtube = true;
        };
      };

      # Balanced lists for a home network: ads/tracking, malware/phishing, and
      # adult content.  The TIF Mini variant avoids the very large memory cost
      # of the full HaGeZi threat-intelligence list.
      filters = [
        {
          enabled = true;
          name = "HaGeZi Multi PRO";
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/pro.txt";
        }
        {
          enabled = true;
          name = "HaGeZi TIF Mini";
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/tif.mini.txt";
        }
        {
          enabled = true;
          name = "HaGeZi NSFW";
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/nsfw.txt";
        }
      ];

      querylog = {
        enabled = true;
        file_enabled = true;
        interval = "7d";
        size_memory = 1000;
      };

      statistics = {
        enabled = true;
        interval = "30d";
      };
    };
  };

  systemd.services.adguardhome = {
    wants = [ "dnsmasq.service" ];
    after = [ "dnsmasq.service" ];
  };

  # AdGuard Home is the only DNS endpoint exposed to LAN clients.
  networking.firewall.allowedTCPPorts = [ 53 ];
  networking.firewall.allowedUDPPorts = [ 53 ];
}
