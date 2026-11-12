{ inputs, pkgs }:

# Use the upstream derivation unchanged to preserve Nixpkgs binary-cache hits.
# Nixpkgs commit 16b463698a5b9f20881b6c5f1150ce37e2456db9 fixes the
# missing system AWS-LC, Oniguruma, SQLite and Zstandard dependencies.
inputs.codex-nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}.codex
