{}:
let
  sources = import ./sources.nix;
  pkgs = import sources.nixpkgs { };
in
pkgs // { inherit sources; nodejs = pkgs.nodejs-10_x; }
