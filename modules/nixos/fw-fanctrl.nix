{ ... }:
# Declarative Framework laptop fan curve via fw-fanctrl.
#
# Replaces the EC's conservative auto curve with an aggressive curve that
# ramps fans to 100% well before the AMD CPU hits its 100 °C thermal limit.
# Higher RPM headroom under sustained load keeps the package below TJmax,
# which lets the boost algorithm hold higher PPT/STAPM and clocks instead
# of throttling — i.e. more performance from the "performance" power
# profile.
#
# Notes:
# - 100 % duty is the hardware ceiling (EC firmware enforced).
# - The service drops back to EC autofanctrl on stop / suspend.
{
  hardware.fw-fanctrl = {
    enable = true;

    config = {
      defaultStrategy = "aggressive";
      # On battery, prefer a quieter curve to preserve runtime.
      strategyOnDischarging = "quiet";

      strategies = {
        aggressive = {
          fanSpeedUpdateFrequency = 2;
          movingAverageInterval = 6;
          speedCurve = [
            { temp = 0;   speed = 15; }
            { temp = 45;  speed = 25; }
            { temp = 55;  speed = 40; }
            { temp = 65;  speed = 60; }
            { temp = 75;  speed = 80; }
            { temp = 82;  speed = 95; }
            { temp = 85;  speed = 100; }
          ];
        };

        quiet = {
          fanSpeedUpdateFrequency = 5;
          movingAverageInterval = 30;
          speedCurve = [
            { temp = 0;   speed = 0; }
            { temp = 50;  speed = 15; }
            { temp = 65;  speed = 30; }
            { temp = 75;  speed = 50; }
            { temp = 85;  speed = 80; }
            { temp = 90;  speed = 100; }
          ];
        };
      };
    };
  };
}
