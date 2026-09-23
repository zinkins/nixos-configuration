{
  description = "My NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # Not in nixpkgs; built from the upstream flake (needs its own nixpkgs for zig_0_16).
    herdr.url = "github:herdrdev/herdr/v0.9.1";
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
