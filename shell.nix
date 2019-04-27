{ pkgs ? import ./nix {} }:
(import ./default.nix { inherit pkgs; } ).napalm-registry-devshell
