{ config, pkgs, ... }:

let
  # The old anti-detect Firefox has a frozen built-in NSS CA store. Generate
  # an explicit negative-trust record for the compromised-chain root.
  # Firefox's cert9.db trust overrides are scoped to each browser profile.
  firefoxNssProfile = pkgs.runCommand "byparr-firefox-nss-distrust" {
    nativeBuildInputs = [ pkgs.nssTools pkgs.openssl ];
  } ''
    mkdir -p "$out"
    expected=86a1ecba089c4a8d3bbe2734c612ba341d813e043cf9e8a862cd5c57a36bbe6b
    actual="$(openssl x509 -in ${./certs/emsign-ecc-root-ca-g3.pem} -outform DER | sha256sum | cut -d' ' -f1)"
    test "$actual" = "$expected" || {
      echo "Unexpected eMudhra root certificate fingerprint" >&2
      exit 1
    }
    certutil -N -d "sql:$out" --empty-password
    certutil -A -d "sql:$out" -n "emSign ECC Root CA - G3" -t "p,p,p" -i ${./certs/emsign-ecc-root-ca-g3.pem}
    certutil -L -d "sql:$out" | grep -F "emSign ECC Root CA - G3"
    certutil -L -d "sql:$out" | grep -F "p,p,p"
  '';
in
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

        # Python/OpenSSL, requests and httpx must use the NixOS trust store,
        # not the CA bundles frozen inside this older OCI image.
        SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
        REQUESTS_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
        CURL_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
      };

      # Independent, read-only CA protections:
      # - OpenSSL/Python uses NixOS's system bundle.
      # - Firefox uses NSS and needs its own negative-trust profile.
      # - The patched utility clones this template to a new writable profile
      #   before *every* browser launch (fail-closed if the template is absent).
      volumes = [
        "${config.security.pki.caBundle}:/etc/ssl/certs/ca-certificates.crt:ro"
        "${firefoxNssProfile}:/etc/byparr-nss-profile:ro"
        "${./byparr-firefox-utils.py}:/app/src/utils.py:ro"
      ];

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
