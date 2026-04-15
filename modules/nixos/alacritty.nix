{ pkgs, inputs, ... }:
let
  alacritty = (inputs.wrappers.wrapperModules.alacritty.apply {
    inherit pkgs;
    settings = {
      font.size = 14;
      font.normal.family = "FiraCode Nerd Font";
    };
  }).wrapper;
in {
  environment.systemPackages = [
    alacritty
  ];
}
