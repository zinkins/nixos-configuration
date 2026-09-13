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
  ];
}
