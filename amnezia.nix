{ pkgs, ... }:

let
  configFile = "/etc/amnezia/amneziawg/awg0.conf";
  runtimeDir = "/run/amneziawg";
  runtimeConfig = "${runtimeDir}/awg0.conf";
  routeTable = "51820";

  splitTunnelUp = pkgs.writeShellScript "amneziawg-split-tunnel-up" ''
    set -euo pipefail

    install -d -m 0700 ${runtimeDir}

    # Build a runtime copy of the AmneziaWG config.  Table=off prevents
    # awg-quick from changing the host's default route.  DNS and hook commands
    # are also stripped so enabling this tunnel cannot unexpectedly change the
    # host-wide network configuration.
    ${pkgs.gawk}/bin/awk '
      BEGIN { in_interface = 0; table_written = 0 }
      /^\[Interface\][[:space:]]*$/ {
        print
        in_interface = 1
        if (!table_written) {
          print "Table = off"
          table_written = 1
        }
        next
      }
      /^\[/ { in_interface = 0 }
      in_interface && /^[[:space:]]*(Table|DNS|PreUp|PostUp|PreDown|PostDown)[[:space:]]*=/ { next }
      { print }
    ' ${configFile} > ${runtimeConfig}
    chmod 0600 ${runtimeConfig}

    ${pkgs.amneziawg-tools}/bin/awg-quick up ${runtimeConfig}

    vpn_ip="$(${pkgs.iproute2}/bin/ip -4 -o addr show dev awg0 | ${pkgs.gawk}/bin/awk 'NR == 1 { split($4, a, "/"); print a[1] }')"
    if [ -z "$vpn_ip" ]; then
      echo "AmneziaWG interface awg0 has no IPv4 address" >&2
      ${pkgs.amneziawg-tools}/bin/awg-quick down ${runtimeConfig} || true
      exit 1
    fi

    # Only traffic explicitly bound to awg0's address uses this table.  The
    # normal host route remains untouched, so qBittorrent peer traffic stays
    # outside the VPN.
    ${pkgs.iproute2}/bin/ip -4 route flush table ${routeTable} || true
    ${pkgs.iproute2}/bin/ip -4 rule del priority 10000 from "$vpn_ip"/32 table ${routeTable} 2>/dev/null || true
    ${pkgs.iproute2}/bin/ip -4 route add default dev awg0 table ${routeTable}
    ${pkgs.iproute2}/bin/ip -4 rule add priority 10000 from "$vpn_ip"/32 table ${routeTable}
  '';

  splitTunnelDown = pkgs.writeShellScript "amneziawg-split-tunnel-down" ''
    set +e

    vpn_ip="$(${pkgs.iproute2}/bin/ip -4 -o addr show dev awg0 2>/dev/null | ${pkgs.gawk}/bin/awk 'NR == 1 { split($4, a, "/"); print a[1] }')"
    if [ -n "$vpn_ip" ]; then
      ${pkgs.iproute2}/bin/ip -4 rule del priority 10000 from "$vpn_ip"/32 table ${routeTable} 2>/dev/null || true
    fi
    ${pkgs.iproute2}/bin/ip -4 route flush table ${routeTable} 2>/dev/null || true

    if [ -e ${runtimeConfig} ]; then
      ${pkgs.amneziawg-tools}/bin/awg-quick down ${runtimeConfig} || true
    fi
    rm -f ${runtimeConfig}
  '';

  proxyStart = pkgs.writeShellScript "media-vpn-proxy-start" ''
    set -euo pipefail

    vpn_ip="$(${pkgs.iproute2}/bin/ip -4 -o addr show dev awg0 | ${pkgs.gawk}/bin/awk 'NR == 1 { split($4, a, "/"); print a[1] }')"
    test -n "$vpn_ip"

    # Listening only on localhost means the proxy is not exposed to the LAN.
    # -b binds every outgoing connection to the VPN interface address, which
    # selects routing table 51820 above.
    exec ${pkgs.microsocks}/bin/microsocks -q -i 127.0.0.1 -p 1080 -b "$vpn_ip"
  '';
in
{
  # Needed by the userspace AmneziaWG implementation.
  boot.kernelModules = [ "tun" ];

  environment.systemPackages = with pkgs; [
    amneziawg-tools
    amneziawg-go
    microsocks
  ];

  systemd.tmpfiles.rules = [
    "d /etc/amnezia/amneziawg 0700 root root -"
  ];

  systemd.services.amneziawg = {
    description = "AmneziaWG split tunnel";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    unitConfig.ConditionPathExists = configFile;

    environment = {
      WG_ENDPOINT_RESOLUTION_RETRIES = "infinity";
      WG_QUICK_USERSPACE_IMPLEMENTATION =
        "${pkgs.amneziawg-go}/bin/amneziawg-go";
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = splitTunnelUp;
      ExecStop = splitTunnelDown;
    };
  };

  # Prowlarr uses this proxy for blocked indexers.  qBittorrent does not use
  # it by default, therefore video data from peers goes over the normal route.
  systemd.services.media-vpn-proxy = {
    description = "SOCKS5 proxy over AmneziaWG for media indexers";
    wantedBy = [ "multi-user.target" ];
    requires = [ "amneziawg.service" ];
    after = [ "amneziawg.service" ];

    unitConfig.ConditionPathExists = configFile;

    serviceConfig = {
      Type = "simple";
      ExecStart = proxyStart;
      Restart = "on-failure";
      RestartSec = 2;
      DynamicUser = true;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
    };
  };
}
