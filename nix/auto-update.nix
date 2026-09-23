{ config, pkgs, ... }:

let
  repoPath = "/etc/nixos";
  flakeHost = "nixos";
  branchName = "master";
  stateDir = "/var/lib/nixos-config-sync";
  runtimeDir = "/run/nixos-config-sync";
  nixosRebuild = "${config.system.build.nixos-rebuild}/bin/nixos-rebuild";

  updateScript = pkgs.writeShellScript "nixos-config-sync" ''
    set -euo pipefail

    repo=${repoPath}
    branch=${branchName}
    flake="$repo#${flakeHost}"
    state_dir=${stateDir}
    runtime_dir=${runtimeDir}

    git_cmd() {
      git -c safe.directory="$repo" -C "$repo" "$@"
    }

    exec 9>"$runtime_dir/update.lock"
    if ! flock -n 9; then
      echo "Another NixOS configuration update is already running; skipping."
      exit 0
    fi

    if ! git_cmd rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo "$repo is not a Git repository." >&2
      exit 1
    fi

    current_branch="$(git_cmd symbolic-ref --quiet --short HEAD || true)"
    if [ "$current_branch" != "$branch" ]; then
      echo "Refusing automatic update: $repo is on branch '$current_branch', expected '$branch'." >&2
      exit 1
    fi

    # Never overwrite local edits, staged changes, or untracked files.
    if [ -n "$(git_cmd status --porcelain=v1 --untracked-files=normal)" ]; then
      echo "Refusing automatic update: $repo has local changes." >&2
      git_cmd status --short >&2
      exit 1
    fi

    origin_url="$(git_cmd remote get-url origin)"
    case "$origin_url" in
      https://github.com/zinkins/nixos-configuration|https://github.com/zinkins/nixos-configuration.git|git@github.com:zinkins/nixos-configuration.git)
        ;;
      *)
        echo "Refusing automatic update: unexpected origin URL '$origin_url'." >&2
        exit 1
        ;;
    esac

    old_rev="$(git_cmd rev-parse HEAD)"
    echo "Current configuration revision: $old_rev"

    # Fetch all configured origin refs so refs/remotes/origin/master is
    # guaranteed to represent the commit we compare and later pull.
    git_cmd fetch --prune origin
    remote_rev="$(git_cmd rev-parse "refs/remotes/origin/$branch")"

    if [ "$old_rev" = "$remote_rev" ]; then
      echo "No configuration update available."
      printf '%s\n' "$old_rev" > "$state_dir/last-seen-revision"
      exit 0
    fi

    # Do not auto-resolve divergence or rewritten history.
    if ! git_cmd merge-base --is-ancestor "$old_rev" "$remote_rev"; then
      echo "Refusing automatic update: origin/$branch is not a fast-forward of local HEAD." >&2
      exit 1
    fi

    echo "New configuration revision available: $remote_rev"
    git_cmd pull --ff-only --no-rebase origin "$branch"
    new_rev="$(git_cmd rev-parse HEAD)"

    if [ "$new_rev" != "$remote_rev" ]; then
      echo "Unexpected revision after git pull: got $new_rev, expected $remote_rev." >&2
      git_cmd reset --hard "$old_rev"
      exit 1
    fi

    restore_git() {
      echo "Restoring repository to previously working revision $old_rev."
      git_cmd reset --hard "$old_rev"
    }

    echo "Preflight 1/2: building the complete NixOS system closure for $new_rev ..."
    if ! ${nixosRebuild} build --flake "$flake"; then
      echo "Build failed; the new configuration will not be activated." >&2
      restore_git
      exit 1
    fi

    echo "Preflight 2/2: checking activation with dry-activate ..."
    if ! ${nixosRebuild} dry-activate --flake "$flake"; then
      echo "dry-activate failed; the new configuration will not be activated." >&2
      restore_git
      exit 1
    fi

    echo "Preflight passed. Activating revision $new_rev ..."
    if ! ${nixosRebuild} switch --flake "$flake"; then
      echo "Activation failed. Restoring the previous Git revision and attempting to reactivate it." >&2
      restore_git

      if ! ${nixosRebuild} switch --flake "$flake"; then
        echo "CRITICAL: failed to reactivate the previous configuration. Manual recovery is required." >&2
      fi
      exit 1
    fi

    printf '%s\n' "$new_rev" > "$state_dir/last-successful-revision"
    printf '%s\n' "$new_rev" > "$state_dir/last-seen-revision"
    echo "NixOS configuration revision $new_rev was activated successfully."
  '';
in
{
  # The updater runs as root, while /etc/nixos may be owned by the admin user.
  # Nix opens local Git flakes through libgit2, so git_cmd's per-command
  # safe.directory setting is not enough for nixos-rebuild.
  programs.git = {
    enable = true;
    config.safe.directory = repoPath;
  };

  systemd.services.nixos-config-sync = {
    description = "Pull, validate and activate NixOS configuration from Git";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    # A successful switch reloads systemd while this service is still running.
    # Do not restart or stop this updater underneath itself.
    restartIfChanged = false;
    unitConfig.X-StopOnRemoval = false;

    environment = config.nix.envVars // {
      HOME = "/root";
    };

    path = with pkgs; [
      coreutils
      gitMinimal
      util-linux
      config.nix.package
      config.programs.ssh.package
    ];

    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "nixos-config-sync";
      RuntimeDirectory = "nixos-config-sync";
      WorkingDirectory = stateDir;
      ExecStart = updateScript;
    };
  };

  systemd.timers.nixos-config-sync = {
    description = "Periodically check Git for NixOS configuration updates";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitInactiveSec = "15min";
      AccuracySec = "1min";
      RandomizedDelaySec = "30s";
      Unit = "nixos-config-sync.service";
    };
  };
}
