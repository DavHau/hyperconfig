// The Cookie header an agent's dashboard receives
// (./hermes-dashboard-public.nix): hermes' own session cookies, nothing
// else, rebuilt pair by pair.
//
// Over HTTPS hermes names its cookies `__Host-hermes_*`
// (hermes_cli/dashboard_auth/cookies.py). A `__Host-` cookie is host-only
// by browser rule, so only this dashboard's own responses can have set
// it: cookies tossed by other davhau.com hosts (Domain=davhau.com from an
// agent slot, Domain=agents.davhau.com from another agent's dashboard) and
// every other site's login cookie stay out, however many there are.
var ALLOWED = /^__Host-hermes_[A-Za-z0-9_]*=/;

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
