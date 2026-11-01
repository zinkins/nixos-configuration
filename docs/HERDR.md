# Herdr network activity and updates

Herdr is installed from `inputs.herdr-nix`, pinned in the repository's
`flake.lock`. The binary does not self-update inside Nix's immutable store.
To update the Herdr **application**, update the `herdr-nix` flake input in
a reviewed PR and merge it. The existing `nixos-config-sync.timer` then
deploys the new package; that timer does **not** update flake inputs on its own.

## Background connections

[Upstream issue #677](https://github.com/herdrdev/herdr/issues/677)
documents recurring background network calls (originally every 30 minutes)
for agent-detection manifest updates. Starting with Herdr 0.7.1 the
`[update]` settings can disable background manifest and release checks
independently. This configuration disables both:

```toml
[update]
version_check = false
manifest_check = false
```

The `herdr-background-settings.service` **user** unit makes these two
changes in the normal `~/.config/herdr/config.toml` (or `XDG_CONFIG_HOME` /
`HERDR_CONFIG_PATH` when present in the user service environment) on login.
It uses `tomlkit` to preserve other config values and comments, writes only
when necessary, and rejects symlinked configs instead of replacing them.
If Herdr is already running, it asks it to reload the settings.

A separate **user** timer, `herdr-manifest-refresh.timer`, checks the
catalog and agent rules **at most once a day** (with up to 15 minutes of
random delay), and only when a Herdr process is present for the user.
This is not a no-network mode: one check downloads a catalog and possibly
multiple TOML files. It replaces repeated automatic polling with one
controlled scheduled batch. The CLI immediately reloads updated manifests
in the running Herdr server.

When Herdr is not running at the scheduled time, the task skips the update.
It will next check at the next scheduled timer firing; this avoids starting
Herdr or making network requests for an inactive terminal session.

## Check

```bash
systemctl --user status herdr-background-settings.service
systemctl --user status herdr-manifest-refresh.timer
systemctl --user list-timers herdr-manifest-refresh.timer
herdr server agent-manifests
```

To activate the new user units immediately after the NixOS deployment in
an existing login session (otherwise reconnect/login):

```bash
systemctl --user daemon-reload
systemctl --user start herdr-background-settings.service
systemctl --user enable --now herdr-manifest-refresh.timer
```

To request a manual refresh (with Herdr running):

```bash
systemctl --user start herdr-manifest-refresh.service
```

If an existing Herdr config is a symlink managed elsewhere (for example,
Home Manager), this unit refuses to overwrite it. Set the two options in
that configuration yourself; the daily timer can still be used.

**Note:** the user timer and settings unit affect the host where this
NixOS configuration is deployed, not other Herdr installs on laptops.
