{
  description = "My NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # Update Codex independently of the stable host package set.
    codex-nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Pin Immich independently. Its separate weekly updater submits a PR,
    # with optional patch-only auto-merge after CI; database migrations remain
    # an operational risk and major/minor upgrades require manual review.
    immich-nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Official hash-verified release binary, without a Rust/Zig source build.
    herdr-nix = {
      url = "github:herdrdev/herdr-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, ... }@inputs:
    let
      system = "x86_64-linux";
    in
    {
      nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [
          ./nix/configuration.nix
          ./nix/amnezia.nix
        ];
      };
    };
}
