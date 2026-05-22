{ pkgs, ... }:
let
  short-videos = pkgs.writeShellApplication {
    name = "short-videos";
    runtimeInputs = [ pkgs.ffmpeg pkgs.gawk pkgs.coreutils ];
    text = builtins.readFile ./short-videos.sh;
  };
in
{
  environment.systemPackages = [ short-videos ];
}
