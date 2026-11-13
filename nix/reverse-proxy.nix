{ ... }:

let
  localDomain = "home";
in
{
  # Explicit http:// local .home sites stay unchanged for older devices.
  # Separate public sharing and authenticated mobile HTTPS hosts use ACME.
  services.caddy = {
    enable = true;
    httpPort = 80;
    httpsPort = 443;

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

      "http://photos.${localDomain}".extraConfig = ''
        # Local setup and administration; phones use immich.zinkin.me.
        reverse_proxy 127.0.0.1:2283
      '';

      "photos.zinkin.me".extraConfig = ''
        # Public HTTPS only to the read-only share proxy. Never forward this
        # hostname to Immich's full API on port 2283.
        reverse_proxy 127.0.0.1:3125
      '';

      "http://adguard.${localDomain}".extraConfig = ''
        reverse_proxy 127.0.0.1:3000
      '';
    };
  };

  # Caddy is the only browser-facing entry point. On the home router, forward
  # *only TCP 443* from the Internet to this NixOS host. TCP 80 stays LAN-only:
  # forwarding 80 would also expose http://*.home virtual hosts via Host headers.
  # TLS-ALPN-01 on TCP 443 allows public certificate issuance without WAN:80.
  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
