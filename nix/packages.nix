{ pkgs, inputs, ... }:

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
    inputs.herdr-nix.packages.${pkgs.stdenv.hostPlatform.system}.herdr

    # Codex and Claude Code are provided by ai-vpn.nix as VPN-only wrappers.
  ];
}
