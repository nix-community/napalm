{
  description = "Build NPM packages in Nix and lightweight NPM registry";

  outputs = { self, nixpkgs }: let
    systems = [ "i686-linux" "x86_64-linux" "aarch64-linux" "x86_64-darwin" ];
  in {
    overlay = final: prev: {
      napalm = {
        inherit (import ./. { pkgs = final; })
          buildPackage snapshotFromPackageLockJson;
      };
    };

    checks = nixpkgs.lib.genAttrs systems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in removeAttrs (import ./. { inherit pkgs; }) [
      "buildPackage" "napalm-registry" "napalm-registry-devshell"
      "snapshotFromPackageLockJson"
    ]);
  };
}
