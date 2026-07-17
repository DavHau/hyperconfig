{ pkgs, inputs, config, ... }:
let
  lib = pkgs.lib;
in
{
  imports = [
    inputs.nix-housing.homeManagerModules.default
  ];

  housing = {
    enable = true;
    houses = {
     dev = {
       modules = [
       ];
       capabilities = {
         readWritePaths = [

         ];
       };
     };
   };
 };
}
