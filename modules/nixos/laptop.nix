# Battery-only behaviour. Compose next to ./dave.nix on laptops.
{ ... }:
{
  imports = [
    ./low-battery-power-off.nix
    ./cpu-powersave-cap.nix
  ];
}
