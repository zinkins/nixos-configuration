# Codex and Claude Code through Amnezia VPN only

`codex`, `claude`, and `claude-cli` are wrapped so they cannot use the server's normal Internet route.

## How it works

The wrappers enter a dedicated Linux network namespace named `ai-vpn` before starting the real CLI binary.

Inside that namespace:

- address: `10.203.0.2/30`;
- gateway to the host: `10.203.0.1`;
- DNS: Quad9 (`9.9.9.9`, `149.112.112.112`);
- IPv6 is disabled;
- all IPv4 forwarding is policy-routed through routing table `51820`, whose default route is `awg0`;
- NAT is allowed only when the outgoing interface is `awg0`;
- a final forwarding `REJECT` rule blocks fallback to the server's normal Internet interface.

This is deliberately stronger than setting `HTTP_PROXY` or `HTTPS_PROXY`: child processes started by the agents (`git`, `curl`, package managers, MCP processes, and so on) inherit the same network namespace. A process that ignores proxy environment variables still cannot bypass the VPN.

If `amneziawg.service`, interface `awg0`, or the VPN default route is unavailable, the wrappers refuse to start. If the tunnel disappears after a CLI has started, the NAT/firewall kill switch prevents fallback to the normal route.

## Commands

Use the commands normally:

```bash
codex
claude
```

`claude-cli` is also available as an alias for `claude`.

## Verify the route

The helper prints the public IPv4 address seen through the isolated namespace:

```bash
ai-vpn-check
```

Compare it with the server's normal public address:

```bash
curl -4 https://api.ipify.org
```

The two addresses should differ when Amnezia VPN is active.

Check the namespace and policy routing:

```bash
systemctl status ai-vpn-namespace amneziawg --no-pager
ip netns list
ip rule show
ip route show table 51820
```

The expected important entries are:

```text
ai-vpn
10010: from 10.203.0.2 lookup 51820
default dev awg0
```

## Fail-closed test

While no Codex/Claude session is doing important work, stop the VPN:

```bash
sudo systemctl stop amneziawg
```

Then:

```bash
ai-vpn-check
codex --version
```

`ai-vpn-check` and `codex` must refuse to start instead of using the ordinary ISP route.

Restore the tunnel:

```bash
sudo systemctl start amneziawg
ai-vpn-check
```

## Authentication and environment

The real CLIs still run as user `sergey`, with `/home/sergey` as HOME, so their normal login/config files continue to work.

The sudo bridge preserves only a small explicit set of potentially useful credentials (`SSH_AUTH_SOCK`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, and `CLAUDE_CODE_OAUTH_TOKEN`). It does not grant the CLIs root privileges; privileges are dropped back to `sergey` before the real CLI starts.
