// See tang_core.h. Portions ported from hansnielsen/tang-esphome,
// Copyright (c) 2026 Hans Nielsen, MIT License (see LICENSE in this directory).

#include "tang_core.h"

#include <cstring>

#include <ArduinoJson.h>

namespace esphome {
namespace tang {

// Not esphome's base64 helpers, on purpose: core/helpers.h has no base64url
// encoder, and its decoder stops silently at the first character outside the
// alphabet. Silently accepting a garbled coordinate must not happen here.
static const char BASE64URL_ALPHABET[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

static int base64url_value(char c) {
  if (c >= 'A' && c <= 'Z')
    return c - 'A';
  if (c >= 'a' && c <= 'z')
    return c - 'a' + 26;
  if (c >= '0' && c <= '9')
    return c - '0' + 52;
  if (c == '-')
    return 62;
  if (c == '_')
    return 63;
  return -1;
}

void base64url_encode(const uint8_t *data, size_t len, std::string &out) {
  out.reserve(out.size() + (len + 2) / 3 * 4);
  size_t i = 0;
  while (i + 3 <= len) {
    uint32_t chunk = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2];
    out.push_back(BASE64URL_ALPHABET[(chunk >> 18) & 0x3F]);
    out.push_back(BASE64URL_ALPHABET[(chunk >> 12) & 0x3F]);
    out.push_back(BASE64URL_ALPHABET[(chunk >> 6) & 0x3F]);
    out.push_back(BASE64URL_ALPHABET[chunk & 0x3F]);
    i += 3;
  }
  if (i < len) {
    // Tail, without padding: JOSE base64url omits '='.
    uint32_t chunk = data[i] << 16;
    bool two = (i + 1 < len);
    if (two)
      chunk |= data[i + 1] << 8;
    out.push_back(BASE64URL_ALPHABET[(chunk >> 18) & 0x3F]);
    out.push_back(BASE64URL_ALPHABET[(chunk >> 12) & 0x3F]);
    if (two)
      out.push_back(BASE64URL_ALPHABET[(chunk >> 6) & 0x3F]);
  }
}

bool base64url_decode(const char *in, uint8_t *out, size_t out_cap, size_t &out_len) {
  out_len = 0;
  uint32_t acc = 0;
  uint8_t bits = 0;
  for (const char *p = in; *p != '\0'; p++) {
    int v = base64url_value(*p);
    if (v < 0)
      return false;
    acc = (acc << 6) | static_cast<uint32_t>(v);
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      if (out_len == out_cap)
        return false;
      out[out_len++] = static_cast<uint8_t>((acc >> bits) & 0xFF);
    }
  }
  // 6 leftover bits can never be canonical; fewer must be zero padding.
  return bits < 6 && (acc & ((1U << bits) - 1)) == 0;
}

bool decode_coordinate(const char *encoded, uint8_t *out, size_t coord_len) {
  uint8_t raw[P256_COORD_LEN];
  size_t raw_len = 0;
  if (coord_len > sizeof(raw) || !base64url_decode(encoded, raw, coord_len, raw_len) || raw_len == 0)
    return false;
  memset(out, 0, coord_len - raw_len);
  memcpy(out + (coord_len - raw_len), raw, raw_len);
  return true;
}

bool valid_kid(const std::string &kid) {
  if (kid.empty() || kid.size() > MAX_KID_LEN)
    return false;
  for (char c : kid) {
    if (base64url_value(c) < 0)
      return false;
  }
  return true;
}

const char *parse_client_jwk(const char *body, size_t len, uint8_t point[P256_POINT_LEN]) {
  JsonDocument doc;
  if (deserializeJson(doc, body, len) != DeserializationError::Ok)
    return "body is not JSON";
  JsonObject jwk = doc.as<JsonObject>();
  if (jwk.isNull())
    return "body is not a JWK object";

  // What tangd checks: kty EC, alg ECMR if present, deriveKey in key_ops if present.
  const char *kty = jwk["kty"];
  if (kty == nullptr || strcmp(kty, "EC") != 0)
    return "kty is not EC";
  JsonVariant alg = jwk["alg"];
  if (!alg.isNull() && (!alg.is<const char *>() || strcmp(alg.as<const char *>(), "ECMR") != 0))
    return "alg is not ECMR";
  JsonVariant key_ops = jwk["key_ops"];
  if (!key_ops.isNull()) {
    bool derive = false;
    for (JsonVariant op : key_ops.as<JsonArray>()) {
      const char *s = op.as<const char *>();
      if (s != nullptr && strcmp(s, "deriveKey") == 0)
        derive = true;
    }
    if (!derive)
      return "key_ops lacks deriveKey";
  }
  const char *crv = jwk["crv"];
  if (crv == nullptr || strcmp(crv, "P-256") != 0)
    return "crv is not P-256";
  const char *x = jwk["x"];
  const char *y = jwk["y"];
  if (x == nullptr || y == nullptr)
    return "x or y missing";

  point[0] = 0x04;
  if (!decode_coordinate(x, point + 1, P256_COORD_LEN) ||
      !decode_coordinate(y, point + 1 + P256_COORD_LEN, P256_COORD_LEN))
    return "malformed coordinates";
  return nullptr;
}

void format_reply_jwk(const uint8_t point[P256_POINT_LEN], std::string &out) {
  out.append("{\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"");
  base64url_encode(point + 1, P256_COORD_LEN, out);
  out.append("\",\"y\":\"");
  base64url_encode(point + 1 + P256_COORD_LEN, P256_COORD_LEN, out);
  out.append("\"}");
}

static bool header_name_is(const std::string &line, size_t colon, const char *name) {
  size_t n = strlen(name);
  if (colon != n)
    return false;
  for (size_t i = 0; i < n; i++) {
    char c = line[i];
    if (c >= 'A' && c <= 'Z')
      c = static_cast<char>(c - 'A' + 'a');
    if (c != name[i])
      return false;
  }
  return true;
}

ParseResult parse_http_request(const std::string &buf, HttpRequest &req) {
  size_t header_end = buf.find("\r\n\r\n");
  if (header_end == std::string::npos)
    return buf.size() > MAX_REQUEST_SIZE ? ParseResult::TOO_LARGE : ParseResult::INCOMPLETE;

  // Request line: METHOD SP target SP HTTP/1.x
  size_t line_end = buf.find("\r\n");
  size_t sp1 = buf.find(' ');
  if (sp1 == std::string::npos || sp1 == 0 || sp1 > line_end)
    return ParseResult::BAD_REQUEST;
  size_t sp2 = buf.find(' ', sp1 + 1);
  if (sp2 == std::string::npos || sp2 == sp1 + 1 || sp2 > line_end)
    return ParseResult::BAD_REQUEST;
  if (buf.compare(sp2 + 1, 7, "HTTP/1.") != 0)
    return ParseResult::BAD_REQUEST;
  req.method = buf.substr(0, sp1);
  std::string target = buf.substr(sp1 + 1, sp2 - sp1 - 1);
  req.path = target.substr(0, target.find('?'));

  req.content_length = 0;
  size_t pos = line_end + 2;
  while (pos < header_end) {
    size_t eol = buf.find("\r\n", pos);
    std::string line = buf.substr(pos, eol - pos);
    pos = eol + 2;
    size_t colon = line.find(':');
    if (colon == std::string::npos || colon == 0)
      return ParseResult::BAD_REQUEST;
    if (header_name_is(line, colon, "transfer-encoding"))
      return ParseResult::NOT_IMPLEMENTED;  // clevis' curl always sends Content-Length
    if (header_name_is(line, colon, "content-length")) {
      size_t v = colon + 1;
      while (v < line.size() && (line[v] == ' ' || line[v] == '\t'))
        v++;
      if (v == line.size())
        return ParseResult::BAD_REQUEST;
      size_t value = 0;
      for (; v < line.size() && line[v] != ' ' && line[v] != '\t'; v++) {
        if (line[v] < '0' || line[v] > '9')
          return ParseResult::BAD_REQUEST;
        value = value * 10 + static_cast<size_t>(line[v] - '0');
        if (value > MAX_REQUEST_SIZE)
          return ParseResult::TOO_LARGE;
      }
      req.content_length = value;
    }
  }

  req.body_offset = header_end + 4;
  if (req.body_offset + req.content_length > MAX_REQUEST_SIZE)
    return ParseResult::TOO_LARGE;
  if (buf.size() < req.body_offset + req.content_length)
    return ParseResult::INCOMPLETE;
  return ParseResult::COMPLETE;
}

Route route_request(const HttpRequest &req, std::string &kid) {
  static const char ADV[] = "/adv";
  static const char REC[] = "/rec/";
  const std::string &path = req.path;

  if (path.compare(0, sizeof(ADV) - 1, ADV) == 0) {
    std::string rest = path.substr(sizeof(ADV) - 1);
    if (rest.empty() || (rest[0] == '/' && rest.find('/', 1) == std::string::npos))
      return req.method == "GET" ? Route::ADV : Route::METHOD_NOT_ALLOWED;
    return Route::NOT_FOUND;
  }
  if (path.compare(0, sizeof(REC) - 1, REC) == 0) {
    // The kid is the last path element; '/' is outside the alphabet, so
    // valid_kid() also rejects anything nested below it.
    std::string candidate = path.substr(sizeof(REC) - 1);
    if (!valid_kid(candidate))
      return Route::NOT_FOUND;
    if (req.method != "POST")
      return Route::METHOD_NOT_ALLOWED;
    kid = candidate;
    return Route::REC;
  }
  return Route::NOT_FOUND;
}

}  // namespace tang
}  // namespace esphome
