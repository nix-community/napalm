{ pkgs ? import ./nix {} }:
(import ./default.nix { inherit pkgs; } ).servant-npm-devshell
