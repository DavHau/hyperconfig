# For checks that run as container tests (systemd-nspawn, the test
# driver's `containers.<name>`): the Nix sandbox allows no setuid bits,
# so /run/wrappers stays empty and pam_unix's account check (its
# unix_chkpwd helper) fails, which keeps every user manager (user@<uid>)
# from starting. The agents' accounts linger and their units reach the
# owner's session bus, so the checks need those managers: this reduces
# the systemd-user PAM stack to permit + pam_systemd. Test-only.
{ lib, pkgs, ... }:
{
  security.pam.services.systemd-user.text = lib.mkForce ''
    account sufficient ${pkgs.linux-pam}/lib/security/pam_permit.so
    session optional ${pkgs.systemd}/lib/security/pam_systemd.so
    session sufficient ${pkgs.linux-pam}/lib/security/pam_permit.so
  '';
}
