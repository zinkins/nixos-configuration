# AGENTS.md

This file is a compact index for coding agents working in this repository.
Do not duplicate subsystem documentation here: follow the linked files as the source of detail.

## Operating rules

- Treat `master` as production/deployable state; keep every change buildable and reversible.
- Prefer **maximum declarativity**: express desired state in NixOS modules instead of manual host changes, imperative setup, or undocumented runtime state.
- When imperative logic is unavoidable, keep it minimal, idempotent, explicit, and owned by a declarative systemd/NixOS definition.
- Prefer a dedicated module for a new subsystem instead of growing `configuration.nix` indefinitely.
- Make the smallest focused change; avoid unrelated refactors, especially around networking, VPN, firewall, storage, boot, SSH, and deployment.
- Read the relevant documentation and module before changing a subsystem; inspect adjacent modules when a change crosses subsystem boundaries.
- If behavior or operator steps change, update the corresponding documentation in the same change.
- Never add or repeat personal information, credentials, tokens, private keys, private VPN configuration, account data, or sensitive diagnostic output.
- Do not copy user-specific values from existing source files into new documentation, comments, examples, issues, or commit messages.
- Use CI as the baseline validation contract; do not claim host/runtime validation unless it was actually performed.

## Architectural invariants

Preserve these unless the task explicitly changes the architecture:

1. `master` remains suitable for automatic deployment.
2. The normal host default route is not replaced by the VPN route.
3. VPN-constrained components fail closed rather than silently falling back to the normal network.
4. qBittorrent peer traffic remains separate from VPN-routed indexer/helper traffic.
5. Browser-facing local service UIs normally go through the reverse proxy instead of opening independent LAN ports.
6. AdGuard Home remains the LAN-facing DNS endpoint; local-zone resolution remains internal.
7. Local service names remain under the existing local domain unless intentionally migrated.
8. Persistent application state is not overwritten on each rebuild unless NixOS is intentionally made authoritative for it.
9. Existing service/container security hardening is preserved or strengthened.
10. Dependencies and startup ordering are declared rather than relying on timing or manual sequencing.

## Documentation index

- [`ADGUARD.md`](ADGUARD.md)
- [`AI-VPN.md`](AI-VPN.md)
- [`AUTO-UPDATE.md`](AUTO-UPDATE.md)
- [`BYPARR.md`](BYPARR.md)
- [`MEDIA-SETUP.md`](MEDIA-SETUP.md)
- [`REVERSE-PROXY.md`](REVERSE-PROXY.md)

## NixOS configuration index

- [`flake.nix`](flake.nix)
- [`configuration.nix`](configuration.nix)
- [`hardware-configuration.nix`](hardware-configuration.nix)
- [`packages.nix`](packages.nix)
- [`networking.nix`](networking.nix)
- [`adguard.nix`](adguard.nix)
- [`reverse-proxy.nix`](reverse-proxy.nix)
- [`homepage.nix`](homepage.nix)
- [`media.nix`](media.nix)
- [`amnezia.nix`](amnezia.nix)
- [`ai-vpn.nix`](ai-vpn.nix)
- [`byparr.nix`](byparr.nix)
- [`auto-update.nix`](auto-update.nix)

## Repository automation and metadata

- [`.github/workflows/nixos-check.yml`](.github/workflows/nixos-check.yml) — validation contract.
- [`.github/dependabot.yml`](.github/dependabot.yml) — dependency update configuration.
- [`flake.lock`](flake.lock) — pinned flake inputs; update intentionally, not by hand-editing.
- [`.gitignore`](.gitignore) — repository ignore rules.

When documentation and implementation disagree, inspect the current NixOS configuration as the executable source of truth and update stale documentation together with the code change.
