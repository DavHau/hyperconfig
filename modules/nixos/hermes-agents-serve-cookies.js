// The Cookie header an agent's published app receives
// (./hermes-agents-serve.nix): an allowlist, rebuilt pair by pair.
//
// Allowed: names that start with a letter or digit (what apps choose for
// themselves), and jupyter's `_xsrf`. Everything a login uses starts with
// an underscore (the private ports' `__Host-hermes_serve` and its
// `__Host-hermes_serve_csrf`, and, should a browser ever send them here,
// the front door's `__Host-hermes` and the mail owner page's
// `__Host-mailgate`), so no number or order of such cookies gets one
// through. Pairs without a name are dropped too.
var ALLOWED = /^(?:[A-Za-z0-9][A-Za-z0-9!#$%&'*+.^_`|~-]*|_xsrf)=/;

function appCookies(r) {
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

export default { appCookies };
