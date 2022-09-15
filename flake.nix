{
  description = "Build NPM packages in Nix and lightweight NPM registry";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem
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
              netlify-cli
              deckdeckgo-starter
              bitwarden-cli
              napalm-registry
              ;
          };

          devShell = napalm.napalm-registry-devshell;
        }
      ) // {
      overlay = final: prev: {
        napalm = import ./. {
          pkgs = final;
        };
      };

      defaultTemplate = {
        path = ./template;
        description = "Template for using Napalm with flakes";
      };
    };
}
