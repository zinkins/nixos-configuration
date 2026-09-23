{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    git
    curl
    wget
    vim
    htop
    ripgrep
    jq
    tree

    # Codex and Claude Code are provided by ai-vpn.nix as VPN-only wrappers.
  ];
}
