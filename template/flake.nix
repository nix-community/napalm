{
  description = "An example of Napalm with flakes";

  # Nixpkgs / NixOS version to use.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # Import napalm
  inputs.napalm.url = "github:nix-community/napalm";

  # Configuring "follows" lets you configure the source for the build environment.
  inputs.napalm.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, napalm }:
    let
      # System types to support.
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "i686-linux" "x86_64-darwin" "aarch64-darwin" ];

      # Helper function to generate an attrset '{ x86_64-linux = f "x86_64-linux"; ... }'.
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      # Advanced: A Nixpkgs overlay.
      overlay = final: prev:
        let
          # To keep the overlay pure, conditionally use the napalm overlay and
          #   default to using the napalm package from the overlaid nixpkgs if
          #   it exists.
          pkgsWithNapalm = if prev ? napalm.buildPackage then prev else napalm.overlay final prev;
        in
        {
          hello-world = pkgsWithNapalm.napalm.buildPackage ./hello-world { };
        };

      # Provide your packages for selected system types.
      packages = forAllSystems (system: {
        hello-world = napalm.legacyPackages."${system}".buildPackage ./hello-world { };
      });

      # The default package for 'nix build'. This makes sense if the
      #   flake provides only one package or there is a clear "main"
      #   package.
      defaultPackage =
        forAllSystems (system: self.packages."${system}".hello-world);
    };
}
