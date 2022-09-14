{
  description = "Build NPM packages in Nix and lightweight NPM registry";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          napalm = import ./. {
            pkgs = nixpkgs.legacyPackages.${system};
          };
        in
        {
          packages = (nixpkgs.lib.filterAttrs (_: nixpkgs.lib.isDerivation) napalm) // {
            default = napalm.napalm-registry;
          };

          legacyPackages = nixpkgs.lib.filterAttrs (_: builtins.isFunction) napalm;

          devShells.default = napalm.napalm-registry-devshell;

          checks.template-simple =
            let
              flake = import (self.templates.simple.path + /flake.nix);
              flakeSelf = flake // flake.outputs;
            in
            (flake.outputs { inherit nixpkgs; self = flakeSelf; napalm = self.outputs; }).packages.${system}.hello-world;
        }) // {

      overlays.default = final: _: nixpkgs.lib.filterAttrs (_: nixpkgs) {
        napalm = import ./. {
          pkgs = final;
        };
      };

      templates.simple = {
        path = ./template;
        description = "Template for using Napalm with flakes";
        welcomeText = ''
          # Simple Napalm Node.js Template

          ## Intended Usage

          This flake is to get you started with a working example of Napalm.

          ## More info

          - [Node.js Website](https://nodejs.org/en/)
          - [Napalm](https://github.com/nix-community/napalm)
        '';
      };
      templates.default = self.templates.simple;
    };
}
