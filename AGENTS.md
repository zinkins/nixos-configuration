# AGENTS.md

This file is a compact index for coding agents working in this repository.
Do not duplicate subsystem documentation here: follow the linked files as the source of detail.

## Operating rules

- Treat `master` as production/deployable state; keep every change buildable and reversible.
- Prefer **maximum declarativity**: express desired state in NixOS modules instead of manual host changes, imperative setup, or undocumented runtime state.
- When imperative logic is unavoidable, keep it minimal, idempotent, explicit, and owned by a declarative systemd/NixOS definition.
- Prefer a dedicated module for a new subsystem instead of growing `nix/configuration.nix` indefinitely.
- Make the smallest focused change; avoid unrelated refactors, especially around networking, VPN, firewall, storage, boot, SSH, and deployment.
- Read the relevant documentation and module before changing a subsystem; inspect adjacent modules when a change crosses subsystem boundaries.
- If behavior or operator steps change, update the corresponding documentation in the same change.
- Never add or repeat personal information, credentials, tokens, private keys, private VPN configuration, account data, or sensitive diagnostic output.
- Do not copy user-specific values from existing source files into new documentation, comments, examples, issues, or commit messages.
- Use CI as the baseline validation contract; do not claim host/runtime validation unless it was actually performed.
- Deployment is via PR merge, not manual host commands: the server auto-pulls and applies `master` on its own (see [`docs/AUTO-UPDATE.md`](docs/AUTO-UPDATE.md)). Never run `nixos-rebuild switch`, `git push`/merge to `master`, or other apply/deploy commands directly on the host or repo on the user's behalf — open a PR and let the user merge it, then the existing `nixos-config-sync.timer` rolls it out within ~15 minutes. Diagnostic reads on the host (`systemctl status`, `journalctl`, `curl`, etc.) are fine.

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

- [`docs/ADGUARD.md`](docs/ADGUARD.md)
- [`docs/AI-VPN.md`](docs/AI-VPN.md)
- [`docs/AUTO-UPDATE.md`](docs/AUTO-UPDATE.md)
- [`docs/BYPARR.md`](docs/BYPARR.md)
- [`docs/HOME-VPN.md`](docs/HOME-VPN.md)
- [`docs/MEDIA-SETUP.md`](docs/MEDIA-SETUP.md)
- [`docs/REVERSE-PROXY.md`](docs/REVERSE-PROXY.md)
- [`docs/SAMBA.md`](docs/SAMBA.md)
- [`docs/SCHOOL-DIARY.md`](docs/SCHOOL-DIARY.md)

## NixOS configuration index

- [`flake.nix`](flake.nix) — flake entry point.
- [`nix/configuration.nix`](nix/configuration.nix) — main host module.
- [`nix/hardware-configuration.nix`](nix/hardware-configuration.nix) — generated hardware baseline.
- [`nix/packages.nix`](nix/packages.nix)
- [`nix/networking.nix`](nix/networking.nix)
- [`nix/adguard.nix`](nix/adguard.nix)
- [`nix/reverse-proxy.nix`](nix/reverse-proxy.nix)
- [`nix/homepage.nix`](nix/homepage.nix)
- [`nix/school-diary.nix`](nix/school-diary.nix)
- [`nix/media.nix`](nix/media.nix)
- [`nix/amnezia.nix`](nix/amnezia.nix)
- [`nix/ai-vpn.nix`](nix/ai-vpn.nix)
- [`nix/byparr.nix`](nix/byparr.nix)
- [`nix/auto-update.nix`](nix/auto-update.nix)
- [`nix/home-vpn.nix`](nix/home-vpn.nix)
- [`nix/samba.nix`](nix/samba.nix)

## Repository automation and metadata

- [`.github/workflows/nixos-check.yml`](.github/workflows/nixos-check.yml) — validation contract.
- [`.github/dependabot.yml`](.github/dependabot.yml) — dependency update configuration.
- [`flake.lock`](flake.lock) — pinned flake inputs; update intentionally, not by hand-editing.
- [`.gitignore`](.gitignore) — repository ignore rules.

Keep operator documentation under `docs/` and NixOS modules under `nix/`. Root-level files should remain limited to repository/tooling entry points.

When documentation and implementation disagree, inspect the current NixOS configuration as the executable source of truth and update stale documentation together with the code change.
