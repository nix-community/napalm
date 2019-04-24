{ pkgs ? import ./nix {} }:
(import ./default.nix).servant-npm-devshell
