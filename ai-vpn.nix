{ lib, pkgs, ... }:

let
  namespaceName = "ai-vpn";
  hostInterface = "ai-vpn-host";
  namespaceInterface = "ai-vpn-ns";
  hostAddress = "10.203.0.1";
  namespaceAddress = "10.203.0.2";
  routeTable = "51820";
  routePriority = "10010";

  aiVpnExec = pkgs.writeShellScript "ai-vpn-exec" ''
    set -euo pipefail

    if [ "$(${pkgs.coreutils}/bin/id -u)" -ne 0 ]; then
      echo "ai-vpn-exec must be invoked through sudo" >&2
      exit 1
    fi

    if [ "''${SUDO_USER:-}" != "sergey" ]; then
      echo "ai-vpn-exec is only allowed for user sergey" >&2
      exit 1
    fi

    target="''${1:-}"
    if [ -z "$target" ]; then
      echo "Usage: ai-vpn-exec {codex|claude|check} [args...]" >&2
      exit 2
    fi
    shift

    case "$target" in
      codex)
        executable=${pkgs.codex}/bin/codex
        ;;
      claude)
        executable=${pkgs.claude-code}/bin/claude
        ;;
      check)
        executable=${pkgs.curl}/bin/curl
        set -- -4 --fail --silent --show-error --max-time 15 https://api.ipify.org
        ;;
      *)
        echo "Unsupported AI VPN command: $target" >&2
        exit 2
        ;;
    esac

    if ! ${pkgs.systemd}/bin/systemctl is-active --quiet amneziawg.service; then
      echo "AmneziaWG is not active; refusing to start $target without VPN." >&2
      exit 1
    fi

    if ! ${pkgs.iproute2}/bin/ip link show awg0 >/dev/null 2>&1; then
      echo "AmneziaWG interface awg0 does not exist; refusing direct-network fallback." >&2
      exit 1
    fi

    if ! ${pkgs.iproute2}/bin/ip -4 route show table ${routeTable} default \
      | ${pkgs.gnugrep}/bin/grep -q 'dev awg0'; then
      echo "VPN routing table ${routeTable} has no default route through awg0." >&2
      exit 1
    fi

    if [ ! -e /run/netns/${namespaceName} ]; then
      echo "AI VPN network namespace is not available." >&2
      exit 1
    fi

    # sudo sanitizes the environment. Restore the normal user identity and
    # command search path before dropping privileges inside the namespace.
    export HOME=/home/sergey
    export USER=sergey
    export LOGNAME=sergey
    export PATH=/run/current-system/sw/bin:/etc/profiles/per-user/sergey/bin:/home/sergey/.local/bin

    exec ${pkgs.iproute2}/bin/ip netns exec ${namespaceName} \
      ${pkgs.util-linux}/bin/setpriv \
        --reuid=sergey \
        --regid=users \
        --init-groups \
        "$executable" "$@"
  '';

  codexVpn = pkgs.writeShellScriptBin "codex" ''
    exec /run/wrappers/bin/sudo -n ${aiVpnExec} codex "$@"
  '';

  claudeVpn = pkgs.writeShellScriptBin "claude" ''
    exec /run/wrappers/bin/sudo -n ${aiVpnExec} claude "$@"
  '';

  claudeCliVpn = pkgs.writeShellScriptBin "claude-cli" ''
    exec /run/wrappers/bin/sudo -n ${aiVpnExec} claude "$@"
  '';

  vpnCheck = pkgs.writeShellScriptBin "ai-vpn-check" ''
    printf 'VPN public IPv4: '
    /run/wrappers/bin/sudo -n ${aiVpnExec} check
    printf '\n'
  '';

  namespaceUp = pkgs.writeShellScript "ai-vpn-namespace-up" ''
    set -euo pipefail

    # Remove stale state left by an interrupted activation.
    ${pkgs.iproute2}/bin/ip rule del priority ${routePriority} from ${namespaceAddress}/32 table ${routeTable} 2>/dev/null || true
    ${pkgs.iproute2}/bin/ip netns del ${namespaceName} 2>/dev/null || true
    ${pkgs.iproute2}/bin/ip link del ${hostInterface} 2>/dev/null || true

    ${pkgs.iproute2}/bin/ip netns add ${namespaceName}
    ${pkgs.iproute2}/bin/ip link add ${hostInterface} type veth peer name ${namespaceInterface}
    ${pkgs.iproute2}/bin/ip link set ${namespaceInterface} netns ${namespaceName}

    ${pkgs.iproute2}/bin/ip address add ${hostAddress}/30 dev ${hostInterface}
    ${pkgs.iproute2}/bin/ip link set ${hostInterface} up

    ${pkgs.iproute2}/bin/ip -n ${namespaceName} address add ${namespaceAddress}/30 dev ${namespaceInterface}
    ${pkgs.iproute2}/bin/ip -n ${namespaceName} link set lo up
    ${pkgs.iproute2}/bin/ip -n ${namespaceName} link set ${namespaceInterface} up
    ${pkgs.iproute2}/bin/ip -n ${namespaceName} route add default via ${hostAddress} dev ${namespaceInterface}

    # Avoid IPv6 becoming an accidental alternate egress path. The namespace
    # intentionally has IPv4 only.
    ${pkgs.iproute2}/bin/ip netns exec ${namespaceName} \
      ${pkgs.procps}/bin/sysctl -q -w net.ipv6.conf.all.disable_ipv6=1
    ${pkgs.iproute2}/bin/ip netns exec ${namespaceName} \
      ${pkgs.procps}/bin/sysctl -q -w net.ipv6.conf.default.disable_ipv6=1

    # Forwarded packets from this namespace are policy-routed into the same
    # table used by the AmneziaWG split tunnel.
    ${pkgs.iproute2}/bin/ip rule add priority ${routePriority} \
      from ${namespaceAddress}/32 table ${routeTable}
  '';

  namespaceDown = pkgs.writeShellScript "ai-vpn-namespace-down" ''
    set +e
    ${pkgs.iproute2}/bin/ip rule del priority ${routePriority} from ${namespaceAddress}/32 table ${routeTable} 2>/dev/null
    ${pkgs.iproute2}/bin/ip netns del ${namespaceName} 2>/dev/null
    ${pkgs.iproute2}/bin/ip link del ${hostInterface} 2>/dev/null
  '';
in
{
  # The namespace gets public DNS directly through the VPN. ip-netns(8)
  # automatically substitutes this file for /etc/resolv.conf inside ai-vpn.
  environment.etc."netns/${namespaceName}/resolv.conf".text = ''
    nameserver 9.9.9.9
    nameserver 149.112.112.112
    options timeout:2 attempts:2
  '';

  environment.systemPackages = [
    codexVpn
    claudeVpn
    claudeCliVpn
    vpnCheck
  ];

  systemd.services.ai-vpn-namespace = {
    description = "Fail-closed network namespace for Codex and Claude Code";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-pre.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = namespaceUp;
      ExecStop = namespaceDown;
    };
  };

  # Forward and masquerade the namespace only through awg0. NixOS generates
  # the normal -i ai-vpn-host -o awg0 accept/NAT rules for this pair.
  networking.nat = {
    enable = true;
    externalInterface = "awg0";
    internalInterfaces = [ hostInterface ];
  };

  # Hard kill switch. Insert it at the very beginning of FORWARD so it runs
  # before generic ESTABLISHED/RELATED rules. If policy routing ever falls back
  # to a normal interface, even an already-open AI connection is rejected.
  networking.firewall.extraCommands = lib.mkAfter ''
    iptables -w -I FORWARD 1 -i ${hostInterface} ! -o awg0 -j REJECT
  '';
  networking.firewall.extraStopCommands = lib.mkBefore ''
    iptables -w -D FORWARD -i ${hostInterface} ! -o awg0 -j REJECT 2>/dev/null || true
  '';

  # Policy routing is asymmetric by design; strict rpfilter would reject valid
  # packets returning through the tunnel.
  networking.firewall.checkReversePath = "loose";

  security.sudo.enable = true;
  security.sudo.extraRules = [
    {
      users = [ "sergey" ];
      commands = [
        {
          command = "${aiVpnExec}";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  # Keep only narrowly scoped credentials that the CLIs may already use in the
  # user's shell. Dangerous loader variables are still stripped by sudo.
  security.sudo.extraConfig = ''
    Defaults:sergey env_keep += "SSH_AUTH_SOCK OPENAI_API_KEY ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN"
  '';
}
