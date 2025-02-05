{pkgs, inputs, ...}: {
  services.odoo.enable = true;
  services.odoo.package = inputs.nixpkgs.legacyPackages.x86_64-linux.odoo;
  boot.binfmt.emulatedSystems = ["x86_64-linux"];
  # nixpkgs.overlays = [(self: super: {
  #   wkhtmltopdf = inputs.nixpkgs.legacyPackages.x86_64-linux.wkhtmltopdf;
  # })];
}
