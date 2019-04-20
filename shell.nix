let pkgs = import ./nix {};
in pkgs.mkShell
  { buildInputs = [ pkgs.nodejs-10_x ];
  }

