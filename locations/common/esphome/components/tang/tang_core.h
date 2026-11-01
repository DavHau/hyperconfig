#pragma once

// Platform-independent pieces of the tang server: base64url, the request/reply
// JWKs and a minimal HTTP/1.x request parser. Nothing here touches the network
// or the curve arithmetic, so tests/tang compiles this file on the host against
// nixpkgs' bearssl and checks it against `jose jwk exc`.
//
// base64url codec, coordinate decoding and kid validation ported from
// hansnielsen/tang-esphome (components/tang/tang.cpp),
// Copyright (c) 2026 Hans Nielsen, MIT License (see LICENSE in this directory).

#include <cstddef>
#include <cstdint>
#include <string>

namespace esphome {
namespace tang {

static constexpr size_t P256_COORD_LEN = 32;
/// Uncompressed SEC1 point: 0x04 || X || Y, what BearSSL's mul() takes.
static constexpr size_t P256_POINT_LEN = 1 + 2 * P256_COORD_LEN;
/// The longest key ID worth looking up: an unpadded base64url SHA-512 thumbprint.
static constexpr size_t MAX_KID_LEN = 86;
/// Request size cap (headers + body). A P-256 /rec request from clevis 22 is
/// ~150 B of body plus ~200 B of curl headers.
static constexpr size_t MAX_REQUEST_SIZE = 2048;

/// Appends the unpadded base64url encoding of data to out.
void base64url_encode(const uint8_t *data, size_t len, std::string &out);
/// Strict base64url decode (rejects '+', '/', anything outside the alphabet and
/// non-zero trailing bits). False on bad input or if the result exceeds out_cap.
bool base64url_decode(const char *in, uint8_t *out, size_t out_cap, size_t &out_len);
/// Decodes a coordinate into a fixed-width, left-zero-padded big-endian buffer.
bool decode_coordinate(const char *encoded, uint8_t *out, size_t coord_len);

/// True if kid is non-empty, at most MAX_KID_LEN and pure base64url.
bool valid_kid(const std::string &kid);

/// Parses clevis' ECMR request JWK ({"alg":"ECMR","crv":"P-256","kty":"EC",x,y})
/// into an uncompressed point. Returns nullptr on success, else a reason for the
/// log. Does NOT check that the point is on the curve: BearSSL's mul() does
/// (it returns 0 for any point outside the P-256 group).
const char *parse_client_jwk(const char *body, size_t len, uint8_t point[P256_POINT_LEN]);
/// Appends the reply JWK {"kty":"EC","crv":"P-256","x":..,"y":..} for point.
void format_reply_jwk(const uint8_t point[P256_POINT_LEN], std::string &out);

enum class ParseResult { INCOMPLETE, COMPLETE, BAD_REQUEST, TOO_LARGE, NOT_IMPLEMENTED };

struct HttpRequest {
  std::string method;
  /// Request target with any query string removed.
  std::string path;
  /// Offset of the body in the buffer passed to parse_http_request().
  size_t body_offset{0};
  size_t content_length{0};
};

/// Parses an HTTP/1.x request accumulated in buf. COMPLETE once the headers and
/// Content-Length bytes of body have arrived.
ParseResult parse_http_request(const std::string &buf, HttpRequest &req);

enum class Route { ADV, REC, NOT_FOUND, METHOD_NOT_ALLOWED };

/// Maps a request onto tang's endpoints. For REC, kid receives the key ID.
/// /adv, /adv/ and /adv/<anything> all serve the one advertisement.
Route route_request(const HttpRequest &req, std::string &kid);

}  // namespace tang
}  // namespace esphome
