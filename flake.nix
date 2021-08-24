{
  description = "Build NPM packages in Nix and lightweight NPM registry";
  inputs.nixpkgs.url = "nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      # List of systems that are supported
      supportedSystems =
        [ "x86_64-linux" "aarch64-linux" "i686-linux" "x86_64-darwin" ];

      # Helper function to generate an attrset '{ x86_64-linux = f "x86_64-linux"; ... }'.
      forAllSystems = f:
        nixpkgs.lib.genAttrs supportedSystems (system: f system);

      # Nixpkgs instantiated for supported system types.
      nixpkgsFor = forAllSystems (system:
        import nixpkgs {
          inherit system;
          overlays = [ self.overlay ];
        });
    in {
      overlay = final: prev: { napalm = import ./. { pkgs = final; }; };

      packages = forAllSystems (system: {
        inherit (nixpkgsFor.${system}.napalm)
          hello-world hello-world-deps netlify-cli deckdeckgo-starter
          bitwarden-cli napalm-registry;
      });

      devShell = forAllSystems
        (system: nixpkgsFor.${system}.napalm.napalm-registry-devshell);

      defaultTemplate = {
        path = ./template;
        description = "Template for using Napalm with flakes";
      };
    };
}
