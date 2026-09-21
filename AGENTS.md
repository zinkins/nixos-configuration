# AGENTS.md

This file is the operating guide for coding agents working in this repository.
Keep changes small, declarative, reviewable, and safe to deploy on a live NixOS host.

## What this repository is

This repository is the source of truth for a single NixOS home server and its local services.
It is a Nix flake based on the NixOS 26.05 channel and exposes one system configuration:

```text
.#nixosConfigurations.nixos
```

`master` is effectively a production/deployment branch. The host periodically pulls `master`, builds the complete system, performs a dry activation, and switches to the new generation only if the checks pass. Treat every change to `master` as potentially deployable.

## Repository structure

The main entry points are:

- `flake.nix` — pins nixpkgs and defines the `nixos` system. It loads `configuration.nix` and the AmneziaWG module.
- `configuration.nix` — base host configuration and the main module import list.
- `hardware-configuration.nix` — hardware/filesystem configuration generated for the host. Do not casually rewrite it.
- `packages.nix` — general command-line packages. VPN-constrained AI tools are intentionally not installed here directly.
- `networking.nix` — basic NetworkManager configuration.
- `adguard.nix` — LAN DNS, ad blocking, and the authoritative local `*.home` namespace.
- `reverse-proxy.nix` — Caddy entry point for browser-facing local services.
- `homepage.nix` — `family.home` dashboard plus its small loopback-only status API.
- `media.nix` — Jellyfin, qBittorrent, Prowlarr, media permissions, hardware transcoding, and torrent firewall rules.
- `amnezia.nix` — AmneziaWG split tunnel and a localhost SOCKS5 proxy used by selected services.
- `ai-vpn.nix` — fail-closed network namespace and wrappers that force supported AI CLIs through AmneziaWG.
- `byparr.nix` — local Podman container used by Prowlarr for Cloudflare-protected indexers; its browser traffic is forced through the VPN-backed SOCKS5 proxy.
- `auto-update.nix` — pulls `master`, validates it, activates it, and restores the previous Git revision if validation or activation fails.
- `*.md` files — operational documentation for the corresponding subsystem.
- `.github/workflows/nixos-check.yml` — CI validation for pushes and pull requests targeting `master`.

When adding a new subsystem, prefer a dedicated `.nix` module imported from `configuration.nix` instead of growing `configuration.nix` indefinitely.

## High-level architecture

### Local DNS

LAN clients use AdGuard Home as their DNS server.

```text
LAN client
   |
   v
AdGuard Home :53
   |-- *.home ------> dnsmasq on loopback :5353
   `-- other DNS ---> encrypted upstream resolvers
```

`dnsmasq` derives the LAN address from the interface carrying the IPv4 default route. Do not replace this with a hard-coded LAN IP unless there is a strong reason.

### Local web services

Caddy is the normal browser-facing entry point:

```text
browser -> http://<service>.home -> Caddy :80 -> service on localhost
```

Typical upstream services include the dashboard, Jellyfin, qBittorrent, Prowlarr, and AdGuard Home.

Keep administrative Web UIs bound to loopback or otherwise inaccessible directly from the LAN when Caddy is intended to be their only browser-facing entry point. Open firewall ports only for protocols that genuinely require direct client access.

The setup intentionally uses plain HTTP for local `*.home` names. Do not introduce local TLS/certificate requirements casually; older LAN clients are part of the compatibility constraints.

### Media traffic

The media stack intentionally separates control/search traffic from bulk torrent traffic:

```text
Prowlarr selected indexers ---> localhost SOCKS5 ---> AmneziaWG
Byparr browser traffic -------> localhost SOCKS5 ---> AmneziaWG
qBittorrent peer traffic --------------------------> normal host route
Jellyfin media traffic ----------------------------> normal LAN route
```

This split is deliberate. Do not turn AmneziaWG into the host default route and do not route qBittorrent peer traffic through the VPN unless the task explicitly changes this architecture.

qBittorrent and Jellyfin share access to the media storage through the `media` group. Preserve ownership/group semantics when changing media paths or service users.

### AI CLI traffic

Supported AI command-line tools use a dedicated network namespace. The namespace is policy-routed through the AmneziaWG routing table and has an explicit forwarding kill switch.

The intended property is **fail closed**: if the VPN interface, routing table, or namespace is unavailable, the AI CLI must fail rather than fall back to the normal host network.

Do not weaken this behavior as a convenience fix.

## Important invariants

Preserve these unless the user explicitly requests an architectural change:

1. `master` remains deployable and should pass a full NixOS build.
2. The normal host default route is not replaced by the AmneziaWG route.
3. VPN-dependent services must fail closed rather than silently use the normal network.
4. qBittorrent peer traffic stays on the normal host route; only explicitly configured search/helper traffic uses the VPN proxy.
5. Browser-facing service UIs normally go through Caddy instead of opening their own LAN firewall ports.
6. AdGuard Home is the LAN-facing DNS server; dnsmasq is loopback-only and authoritative for the local `home` zone.
7. Local service names are kept under the `home` suffix.
8. Service ordering is expressed with systemd `requires`, `wants`, `after`, and mount dependencies when availability matters.
9. Persistent application state should not be overwritten on every rebuild unless NixOS is intentionally made authoritative for that state.
10. Security hardening already present on custom services/containers should be preserved or strengthened, not removed to work around an unrelated problem.

## How agents should make changes

Before editing, read the relevant `.nix` module and its matching Markdown documentation. Also inspect adjacent modules when the change crosses DNS, proxy, VPN, firewall, storage, or systemd boundaries.

Prefer the smallest module-local change that satisfies the task. Avoid opportunistic refactors in the same commit, especially in networking, firewall, VPN, boot, filesystem, SSH, or auto-update code.

For shell scripts embedded in Nix:

- use `set -euo pipefail` for non-trivial scripts unless failure-tolerant cleanup is intentional;
- use package-qualified executable paths where practical;
- quote shell values correctly;
- make cleanup/idempotency explicit for systemd start/stop scripts;
- prefer failing safely over adding a direct-network or permissive fallback.

For systemd services:

- express real dependencies explicitly;
- keep services loopback-only when they do not need LAN exposure;
- retain hardening directives such as `NoNewPrivileges`, `ProtectSystem`, `ProtectHome`, and restricted address families where compatible;
- do not run a service as root merely to avoid solving permissions correctly.

For firewall changes, document why every newly opened port must be reachable directly.

If behavior or operator steps change, update the corresponding Markdown documentation in the same change.

## Validation

CI runs these checks and agents should use the same commands when a Nix environment is available:

```bash
nix flake check --show-trace
nix build .#nixosConfigurations.nixos.config.system.build.toplevel \
  --no-link --print-build-logs
```

On the actual host, a safe additional pre-activation check is:

```bash
sudo nixos-rebuild dry-activate --flake .#nixos
```

Do not run `nixos-rebuild switch` on a live host unless the task explicitly calls for activation. The repository's automatic updater is designed to perform build, dry activation, and switch in order.

For a service change, also identify a focused runtime verification command, for example `systemctl status`, `journalctl`, `curl` against a loopback endpoint, DNS lookup, routing inspection, or a service-specific health endpoint. Do not claim runtime verification if it was not actually performed on the host.

## Auto-deployment behavior

`auto-update.nix` deliberately protects the host from unsafe repository state. The updater:

1. requires the checkout to be on `master`;
2. refuses to run with local/staged/untracked changes;
3. verifies the expected Git remote;
4. fetches and accepts only a fast-forward of the current revision;
5. builds the full NixOS system;
6. runs `dry-activate`;
7. switches only after both preflight steps succeed;
8. restores the previous Git revision if validation or activation fails, and attempts to reactivate the previous configuration after a failed switch.

Do not "fix" an updater failure by making it discard arbitrary local changes, accept rewritten history, or bypass its validation steps.

## Privacy and secrets

This is a public repository. Agents must not add personal information or secrets to code, documentation, examples, comments, logs, issues, or commit messages.

Do not add or duplicate values such as:

- passwords, password reset data, API keys, access tokens, OAuth/session cookies, or authentication headers;
- VPN private keys or complete private VPN configuration files;
- SSH private keys;
- personal email addresses, phone numbers, street addresses, real names, family information, or precise personal geolocation;
- private service credentials or account identifiers;
- diagnostic dumps that contain any of the above.

Public infrastructure details that are necessary to understand the repository (module names, local service names, ports, service dependencies, generic filesystem roles) may be documented, but prefer describing the role of a value rather than copying a person-specific value.

If an existing source file contains user-specific data, do not repeat it in new documentation. Preserve it only when required for the requested code change. When introducing new credentials, reference a root-owned/runtime file or another secret-management mechanism instead of committing the credential itself.

Never place private VPN configuration content in this repository. The AmneziaWG module intentionally reads its runtime configuration from outside Git.

## Git and change discipline

Because `master` can be automatically deployed:

- keep commits focused and reversible;
- do not combine unrelated cleanup with functional changes;
- do not force-push or rewrite deployment history as part of normal maintenance;
- prefer a pull request for risky changes when the user's workflow allows it;
- write commit/PR descriptions in terms of behavior and safety properties, not household or personal details.

When a task explicitly requests a direct change to `master`, still perform the same review and validation reasoning you would use for a production deployment.

## Documentation map

Consult the subsystem documentation before changing its behavior:

- `ADGUARD.md` — DNS/AdGuard operation and troubleshooting.
- `AI-VPN.md` — VPN-constrained AI CLI design and checks.
- `AUTO-UPDATE.md` — repository synchronization and activation workflow.
- `BYPARR.md` — Byparr/Prowlarr integration and troubleshooting.
- `MEDIA-SETUP.md` — media services and storage behavior.
- `REVERSE-PROXY.md` — Caddy and local service URLs.

Documentation can lag behind code. When they disagree, inspect the current Nix modules and then update the documentation as part of the change.

## Before finishing a task

Confirm all of the following:

- the change is in the correct module;
- relevant networking/VPN/firewall/storage dependencies were considered;
- no personal information or secret was introduced;
- full flake/system validation was run when the environment allowed it;
- runtime validation is reported accurately (performed vs. suggested);
- related documentation was updated if behavior changed;
- the resulting `master` state remains safe for automatic deployment.
