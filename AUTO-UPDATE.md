# Automatic NixOS configuration updates

The server watches the `master` branch of:

```text
https://github.com/zinkins/nixos-configuration
```

The local checkout is expected at:

```text
/etc/nixos
```

## How it works

`nixos-config-sync.timer` starts the updater roughly every 15 minutes (and shortly after boot).

For each run the updater:

1. verifies that `/etc/nixos` is a Git repository on `master`;
2. refuses to continue if there are local/staged/untracked changes;
3. verifies that `origin` points to `zinkins/nixos-configuration`;
4. fetches `origin/master`;
5. does nothing when the local revision is already current;
6. refuses non-fast-forward/diverged history;
7. runs `git pull --ff-only`;
8. runs a full `nixos-rebuild build --flake /etc/nixos#nixos`;
9. runs `nixos-rebuild dry-activate --flake /etc/nixos#nixos`;
10. only if both preflight steps succeed, runs `nixos-rebuild switch --flake /etc/nixos#nixos`.

If the build or dry activation fails, the checkout is reset to the previous revision and the running system is left unchanged.

If `switch` fails, the checkout is reset to the previous revision and the updater attempts to switch back to that previous configuration.

The service state is stored under:

```text
/var/lib/nixos-config-sync
```

Logs are kept in the systemd journal.

## First activation

Because the updater itself is part of the NixOS configuration, install this revision once manually:

```bash
sudo git -c safe.directory=/etc/nixos -C /etc/nixos pull --ff-only origin master
sudo nixos-rebuild switch --flake /etc/nixos#nixos
```

After that the timer handles later changes automatically.

## Check status

```bash
systemctl status nixos-config-sync.timer
systemctl list-timers nixos-config-sync.timer
```

Run an update check immediately:

```bash
sudo systemctl start nixos-config-sync.service
```

Watch its log:

```bash
journalctl -u nixos-config-sync.service -f
```

Show the latest completed run:

```bash
journalctl -u nixos-config-sync.service -n 100 --no-pager
```

## Local changes

The updater intentionally stops when `/etc/nixos` is not clean. This prevents an automatic pull from overwriting work done directly on the server.

Inspect the changes with:

```bash
git -C /etc/nixos status
```

Commit, stash, or remove them before starting the updater again.

## Security note

An automatic `nixos-rebuild switch` runs configuration from `master` with root privileges. Treat write access to the GitHub repository and its `master` branch as administrative access to this server. The updater intentionally accepts only the configured repository, the `master` branch, and fast-forward history; it does not automatically resolve branch divergence or rewritten history.
