{ ... }:

{
  # Run Byparr locally for Cloudflare-protected Prowlarr indexers.
  # The browser is forced through the localhost SOCKS5 proxy provided by
  # media-vpn-proxy, which in turn binds outbound connections to awg0.
  virtualisation.oci-containers = {
    backend = "podman";

    containers.byparr = {
      # GitHub releases use names like v3.0.4, but GHCR publishes the stable
      # container tag without the leading "v" (3.0.4).
      image = "ghcr.io/thephaseless/byparr:3.0.4";
      autoStart = true;

      environment = {
        HOST = "127.0.0.1";
        PORT = "8191";
        LOG_LEVEL = "INFO";
        PROXY_SERVER = "socks5://127.0.0.1:1080";
      };

      # Host networking lets Byparr reach the existing localhost-only SOCKS5
      # proxy without exposing its own API to the LAN. HOST=127.0.0.1 keeps
      # port 8191 loopback-only.
      extraOptions = [
        "--network=host"
        "--shm-size=512m"
        "--security-opt=no-new-privileges"
      ];
    };
  };

  # Do not start Byparr before the VPN-backed SOCKS service. If that proxy is
  # unavailable later, Playwright keeps using the configured SOCKS endpoint
  # and requests fail instead of silently switching to the normal host route.
  systemd.services.podman-byparr = {
    requires = [ "media-vpn-proxy.service" ];
    after = [ "media-vpn-proxy.service" ];
  };
}
