{
  description = "Build NPM packages in Nix and lightweight NPM registry";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }:
    let
      internal_overlay = final: prev: {
        napalm = import ./. {
          pkgs = final;
        };
      };
    in
    flake-utils.lib.eachDefaultSystem
      (
        system:
        let
          pkgs = import nixpkgs { inherit system; overlays = [ internal_overlay ]; };
        in
        {
          legacyPackages = {
            inherit (pkgs.napalm)
              buildPackage
              snapshotFromPackageLockJson
              ;
          };

          packages = {
            inherit (pkgs.napalm)
              hello-world hello-world-deps netlify-cli deckdeckgo-starter
              bitwarden-cli napalm-registry
              ;
          };

          devShell = pkgs.napalm.napalm-registry-devshell;
        }
      ) // {
      overlay = final: prev: builtins.removeAttrs (internal_overlay final prev) [
        "hello-world"
        "hello-world-deps"
        "netlify-cli"
        "deckdeckgo-starter"
        "bitwarden-cli"
        "napalm-registry"
      ];

      defaultTemplate = {
        path = ./template;
        description = "Template for using Napalm with flakes";
      };
    };
}
