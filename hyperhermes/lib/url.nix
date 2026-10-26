# URLs of published host names, as exposure (../modules/exposure.nix)
# serves them. The one place that knows how scheme and port make an origin;
# modules use exposure.urlOf, which is this function applied to the mode's
# scheme and port.
{ lib }:
{
  # Origin of a host: https without an explicit port (public mode), or the
  # given scheme on the given port (local mode).
  originOf =
    {
      scheme ? "https",
      port ? null,
    }:
    host: "${scheme}://${host}${lib.optionalString (port != null) ":${toString port}"}";
}
