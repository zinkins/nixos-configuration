{ ... }:

let
  localDomain = "home";
in
{
  # Friendly local names. Explicit http:// site addresses keep this LAN-only
  # setup certificate-free, which is useful for older clients and TVs.
  services.caddy = {
    enable = true;
    httpPort = 80;
    httpsPort = null;

    virtualHosts = {
      "http://family.${localDomain}".extraConfig = ''
        handle_path /school-diary/* {
          reverse_proxy 127.0.0.1:8084
        }
        handle_path /family-location/* {
          reverse_proxy 127.0.0.1:8085
        }
        handle {
          reverse_proxy 127.0.0.1:8082
        }
      '';

      "http://prowlarr.${localDomain}".extraConfig = ''
        reverse_proxy 127.0.0.1:9696
      '';

      "http://qbittorrent.${localDomain}".extraConfig = ''
        reverse_proxy 127.0.0.1:8080 {
          # qBittorrent validates Host by default. Keep the upstream Host local
          # and make the browser origin headers match it. qBittorrent checks
          # Host, Origin and Referer for requests for Web UI assets and returns
          # 401 when Caddy only rewrites Host.
          header_up Host 127.0.0.1:8080
          header_up Origin http://127.0.0.1:8080
          header_up Referer http://127.0.0.1:8080/
        }
      '';

      "http://jellyfin.${localDomain}".extraConfig = ''
        reverse_proxy 127.0.0.1:8096
      '';

      "http://adguard.${localDomain}".extraConfig = ''
        reverse_proxy 127.0.0.1:3000
      '';
    };
  };

  # Caddy is the only browser-facing entry point for the proxied Web UIs.
  networking.firewall.allowedTCPPorts = [ 80 ];
}
