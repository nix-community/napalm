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
      supportedSystems = [ "x86_64-linux" ];

      # Helper function to generate an attrset '{ x86_64-linux = f "x86_64-linux"; ... }'.
      forAllSystems = f:
        nixpkgs.lib.genAttrs supportedSystems (system: f system);

      # Nixpkgs instantiated for supported system types.
      nixpkgsFor = forAllSystems (system:
        import nixpkgs {
          inherit system;
          # Add napalm to you overlay's list
          overlays = [
            self.overlay
            napalm.overlay
          ];
        });

    in {
      # A Nixpkgs overlay.
      overlay = final: prev:
        {
          # Example package
          hello-world-deps = final.napalm.buildPackage ./hello-world-deps { };
        };

      # Provide your packages for selected system types.
      packages = forAllSystems (system: {
        inherit (nixpkgsFor.${system}) hello-world-deps;
      });

      # The default package for 'nix build'. This makes sense if the
      # flake provides only one package or there is a clear "main"
      # package.
      defaultPackage =
        forAllSystems (system: self.packages.${system}.hello-world-deps);
    };
}
