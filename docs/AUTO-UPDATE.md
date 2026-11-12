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
9. runs `nixos-rebuild dry-activate --flake /etc/nixos#nixos` as root;
10. only if both preflight steps succeed, runs `nixos-rebuild switch --flake /etc/nixos#nixos` as root.

The systemd service itself runs as root, so its `dry-activate` and `switch` steps do not require interactive authentication.

`/etc/nixos` is declared as a system-wide Git `safe.directory`. This is required when the checkout is owned by the admin user: Nix opens a local Git flake through libgit2 as root and otherwise rejects the ownership mismatch.

If the build or dry activation fails, the checkout is reset to the previous revision and the running system is left unchanged.

If `switch` fails, the checkout is reset to the previous revision and the updater attempts to switch back to that previous configuration.

The service state is stored under:

```text
/var/lib/nixos-config-sync
```

Logs are kept in the systemd journal.

## Automatic Codex and Herdr updates

`.github/workflows/codex-update.yml` (the **Update Codex and Herdr** GitHub
Actions workflow) runs daily at **03:23 UTC**, or manually via
**Actions → Update Codex and Herdr → Run workflow**.

1. Updates **only** the `codex-nixpkgs` and `herdr-nix` flake inputs and
   Herdr's transitive flake dependencies; protects the stable host `nixpkgs`.
2. If `flake.lock` changes, runs `nix flake check --show-trace` and builds the
   **complete NixOS system** before publishing any PR.
3. Creates/updates one PR (`automation/update-codex-herdr`) using a dedicated
   GitHub token, which causes the normal `pull_request` **Validate** check to run.
4. Enables GitHub-native **auto-merge** for that PR with a locked head SHA.
   GitHub merges only when the required **Validate** check passes.
5. Once the PR is merged, `nixos-config-sync.timer` on the server pulls master,
   builds the full system, dry-activates and switches it (approximately every 15
   minutes). If host preflight/activation fails, the updater rolls back.

When a PR changes `nix/codex-package.nix`, the required **Validate** job also
updates `codex-nixpkgs` in its temporary CI checkout and builds the complete
system with that candidate. This detects package-recipe regressions even when
the PR still pins an older Codex version; the CI check does not commit the lock
file or deploy anything.

A failed flake check, system build or required PR check **blocks deployment**.
A failed PR remains for diagnosis. The updater does not alter network/VPN
settings, upgrade the stable Nixpkgs input, force-push master, or bypass rulesets.

Updates follow Codex availability in `nixos-unstable` and Herdr availability
in `herdrdev/herdr-nix`: either may lag behind its upstream application release.
A new input revision does not always imply a different package version. An
already-running Codex or Herdr process may need restarting to use the upgraded
binary. Herdr's separate daily detection-manifest refresh is configured in
[`HERDR.md`](HERDR.md); it is not the application version updater.

### One-time GitHub authorization (required)

GitHub currently requires a successful `Validate` check **from GitHub
Actions** on any PR targeting master. PRs created using a workflow's default
`GITHUB_TOKEN` do not trigger an unattended regular `pull_request` check;
a manually dispatched workflow check does not satisfy this particular
required-check rule. The automation therefore needs a one-time repository
Actions secret named **`AUTO_UPDATE_TOKEN`**.

1. Create a **fine-grained GitHub personal access token** limited to the
   `zinkins/nixos-configuration` repository, with
   **Contents: Read and write** and **Pull requests: Read and write**.
   Choose an appropriate expiration and rotate before it expires.
2. Go to repository **Settings → Secrets and variables → Actions →
   New repository secret**, name it `AUTO_UPDATE_TOKEN` and paste the
   token **there**, not in Git, PR comments or chat.
3. Verify that **Settings → Actions → General → Workflow permissions →
   Allow GitHub Actions to create and approve pull requests** is enabled.
   Repository **Settings → General → Pull Requests → Allow auto-merge**
   must also be enabled (the workflow never bypasses branch protection).
4. Trigger **Update Codex and Herdr** once in GitHub Actions and verify that
   any generated PR receives a normal `Validate` check and auto-merges
   only after it succeeds.

If the secret is absent or expired, the workflow fails early without opening
a PR or altering master. This is intentional: no protection bypass and no
fallback to manual-approval bot PRs. If there is no changed input revision,
no PR is needed.

To roll back an automatically merged update, revert the merged commit via a
new PR and let the existing sync timer apply it. New versions may still have
runtime issues despite passing build tests; inspect the system journal if
problems arise.

## First activation

Because the updater itself is part of the NixOS configuration, install this revision once manually:

```bash
sudo git config --global --add safe.directory /etc/nixos
sudo git -c safe.directory=/etc/nixos -C /etc/nixos pull --ff-only origin master
sudo nixos-rebuild switch --flake /etc/nixos#nixos
```

After that the timer handles later changes automatically.

If an older updater has already failed with `repository path '/etc/nixos' is not owned by current user`, bootstrap this setting once in root's Git configuration and retry the service:

```bash
sudo git config --global --add safe.directory /etc/nixos
sudo systemctl start nixos-config-sync.service
```

After the updated configuration is activated, the same exception is provided declaratively by `/etc/gitconfig`.

## Manual preflight check

To reproduce the updater checks manually, use:

```bash
(cd /var/tmp && nixos-rebuild build --flake /etc/nixos#nixos)
sudo nixos-rebuild dry-activate --flake /etc/nixos#nixos
```

`build` does not require root privileges. It creates a `result` symlink in the current working directory, so the example runs it from `/var/tmp` instead of `/etc/nixos`. The repository also ignores standard Nix build-result links (`result` and `result-*`) as an additional safeguard.

`dry-activate` does require root privileges: on NixOS 26.05 it invokes `switch-to-configuration` through `systemd-run`, which requires administrative privileges. Running `dry-activate` without `sudo` can fail with an `interactive authentication` / `Access denied` error even when the configuration itself is valid.

To apply the configuration manually after a successful preflight:

```bash
sudo nixos-rebuild switch --flake /etc/nixos#nixos
```

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

If the only untracked item is a `result` symlink left by a manual `nixos-rebuild build` run from `/etc/nixos`, it is safe to remove:

```bash
rm -f /etc/nixos/result
```

Then rerun `git -C /etc/nixos status`. After the `.gitignore` change in this repository is present locally, normal `result` and `result-*` build links no longer make the checkout dirty.

Commit, stash, or remove any other local changes before starting the updater again.

## Security note

An automatic `nixos-rebuild switch` runs configuration from `master` with root privileges. Treat write access to the GitHub repository and its `master` branch as administrative access to this server. The updater intentionally accepts only the configured repository, the `master` branch, and fast-forward history; it does not automatically resolve branch divergence or rewritten history.
