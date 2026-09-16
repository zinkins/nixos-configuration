{ lib, pkgs, ... }:

let
  localDomain = "home.arpa";
  dnsmasqRuntimeConfig = "/run/dnsmasq-home-arpa.conf";
in
{
  # Handy for checking the local DNS service with `dig` and `nslookup`.
  environment.systemPackages = [ pkgs.dnsutils ];

  # Friendly local names. Explicit http:// site addresses keep this LAN-only
  # setup certificate-free, which is useful for older clients and TVs.
  services.caddy = {
    enable = true;
    httpPort = 80;
    httpsPort = null;

    virtualHosts = {
      "http://prowlarr.${localDomain}".extraConfig = ''
        reverse_proxy 127.0.0.1:9696
      '';

      "http://qbittorrent.${localDomain}".extraConfig = ''
        reverse_proxy 127.0.0.1:8080 {
          # qBittorrent validates Host by default. Keep the upstream Host local
          # while Caddy still supplies X-Forwarded-* headers for the client.
          header_up Host 127.0.0.1:8080
        }
      '';

      "http://jellyfin.${localDomain}".extraConfig = ''
        reverse_proxy 127.0.0.1:8096
      '';
    };
  };

  # Local DNS for *.home.arpa. The server may get its LAN address through DHCP,
  # so the A records are generated at service start from the interface carrying
  # the IPv4 default route instead of hard-coding an address in Git.
  services.dnsmasq = {
    enable = true;
    resolveLocalQueries = false;
    settings = {
      conf-file = [ dnsmasqRuntimeConfig ];
      local = "/${localDomain}/";
      local-service = "net";
      domain-needed = true;
      bogus-priv = true;
    };
  };

  systemd.services.dnsmasq = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    # This runs before the module's built-in `dnsmasq --test`, because that
    # test already reads the runtime conf-file declared above.
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
interface-name=prowlarr.${localDomain},$lan_if/4
interface-name=qbittorrent.${localDomain},$lan_if/4
interface-name=jellyfin.${localDomain},$lan_if/4
EOF
    '';
  };

  # Caddy is the browser-facing entry point. DNS is exposed to the local
  # network so the router/clients can use this server as their resolver.
  networking.firewall.allowedTCPPorts = [ 53 80 ];
  networking.firewall.allowedUDPPorts = [ 53 ];
}
