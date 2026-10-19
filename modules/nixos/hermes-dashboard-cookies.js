// The Cookie header an agent's dashboard receives
// (./hermes-dashboard-public.nix): hermes' own cookies, nothing else,
// rebuilt pair by pair.
//
// Over HTTPS without a path prefix hermes names its cookies `__Host-`
// (hermes_cli/dashboard_auth/cookies.py): the session (`hermes_session_at`,
// `_rt`, `_provider`), the PKCE state of a browser sign-in
// (`hermes_session_pkce`) and the auto-SSO loop guard
// (`hermes_sso_attempt`). A `__Host-` cookie is host-only by browser rule,
// so only this dashboard's own responses can have set it.
//
// Hermes Mobile signs in through the native flow and keeps the tokens
// itself; it sends them as bare `hermes_session_at`, `_rt` and `_provider`
// (hermes-mobile CookieSerialization.kt), which hermes reads after the
// `__Host-` names. A bare name can be tossed from a sibling host
// (Domain=davhau.fyi or Domain=<agent>.davhau.fyi from another agent's page
// or this agent's own serve ports and slot). That is harmless: hermes
// prefers the `__Host-` cookie when both are there, and a tossed token must
// still carry aud=hermes-<this agent>, i.e. be a login of this dashboard's
// own members. Every other cookie, login cookies of other hosts included,
// stays out, however many there are.
var ALLOWED =
  /^(__Host-hermes_(session_(at|rt|provider|pkce)|sso_attempt)|hermes_session_(at|rt|provider))=/;

function hermesCookies(r) {
  // nginx joins repeated Cookie headers (HTTP/2 sends one per pair) with "; ".
  var header = r.variables.http_cookie;
  if (!header) {
    return "";
  }
  return header
    .split(";")
    .map(function (pair) {
      return pair.trim();
    })
    .filter(function (pair) {
      return ALLOWED.test(pair);
    })
    .join("; ");
}

export default { hermesCookies };
