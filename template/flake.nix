{
  description = "An example of Napalm with flakes";

  # Nixpkgs / NixOS version to use.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # Import napalm
  inputs.napalm.url = "github:nix-community/napalm";

  outputs = { self, nixpkgs, napalm }:
    let
      # Generate a user-friendly version number.
      version = builtins.substring 0 8 self.lastModifiedDate;

      # System types to support.
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "i686-linux" "x86_64-darwin" "aarch64-darwin" ];

      # Helper function to generate an attrset '{ x86_64-linux = f "x86_64-linux"; ... }'.
      forAllSystems = f:
        nixpkgs.lib.genAttrs supportedSystems (system: f system);

      # Nixpkgs instantiated for supported system types.
      nixpkgsFor = forAllSystems (system:
        import nixpkgs {
          inherit system;
          # Add napalm to you overlay's list
          overlays = [
            self.overlays.default
            napalm.overlays.default
          ];
        });

    in
    {
      # A Nixpkgs overlay.
      overlays = {
        default = final: prev: {
          # Example package
          hello-world = final.napalm.buildPackage ./hello-world { };
        };
      };

      # Provide your packages for selected system types.
      packages = forAllSystems (system: {
        inherit (nixpkgsFor.${system}) hello-world;

        # The default package for 'nix build'. This makes sense if the
        # flake provides only one package or there is a clear "main"
        # package.
        default = self.packages.${system}.hello-world;
      });
    };
}
