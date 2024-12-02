{pkgs, ...}: let
  ocr = pkgs.writers.writePython3Bin "ocr"
    {
      libraries = [pkgs.python3.pkgs.pytesseract];
    }
    ./ocr.py;
in {
  environment.systemPackages = [
    ocr
  ];
}
