{
  description = "Build NPM packages in Nix and lightweight NPM registry";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }:
    (flake-utils.lib.eachDefaultSystem
      (system:
        let
          napalm = import ./. {
            pkgs = nixpkgs.legacyPackages."${system}";
          };
        in
        {
          legacyPackages = {
            inherit (napalm)
              buildPackage
              snapshotFromPackageLockJson
              ;
          };

          packages = {
            inherit (napalm)
              hello-world
              hello-world-deps
              hello-world-deps-v3
              hello-world-workspace-v3
              deps-alias
              netlify-cli
              deckdeckgo-starter
              bitwarden-cli
              napalm-registry
              ;
          };

          devShells = {
            default = napalm.napalm-registry-devshell;
          };
        }
      )
    ) // {
      overlays = {
        default = final: prev: {
          napalm = import ./. {
            pkgs = final;
          };
        };
      };

      templates = {
        default = {
          path = ./template;
          description = "Template for using Napalm with flakes";
        };
      };
    };
}
