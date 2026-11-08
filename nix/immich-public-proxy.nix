{ inputs, pkgs, ... }:

let
  # This public hostname serves only intentionally shared links. Never route
  # it to the full Immich API, its login, or the private /myraid1/nas/Photos.
  publicUrl = "https://photos.zinkin.me";
in
{
  # Use the hardened native NixOS service, without a Podman container.
  # The host's stable Nixpkgs package is an old IPP 1.x release; select the
  # newer IPP release alongside Immich 3.x from its own pinned Nixpkgs input.
  services.immich-public-proxy = {
    enable = true;
    package = inputs.immich-nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}.immich-public-proxy;
    immichUrl = "http://127.0.0.1:2283";
    port = 3000;
    openFirewall = false;
  };

  # IPP runs natively on the same host, so 127.0.0.1 reaches Immich.
  # Explicit public URL makes previews in messaging apps use HTTPS.
  systemd.services.immich-public-proxy = {
    requires = [ "immich-server.service" ];
    after = [ "immich-server.service" ];
    environment.PUBLIC_BASE_URL = publicUrl;
  };
}
