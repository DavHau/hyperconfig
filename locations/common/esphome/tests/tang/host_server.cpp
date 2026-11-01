// Host build of the tang component's request path, for run.sh.
//
// Compiles components/tang/tang_core.cpp unchanged against nixpkgs' bearssl and
// does what TangServer::read_()/handle_rec_() do on the device, minus ESPHome:
// same parser, same router, same JWK handling, same br_ec_p256_m15.mul() call.
//
//   host_server <port>        serve /adv and /rec/<kid> (blocking, one client at a time)
//   host_server --exc <jwk>   print the /rec reply for the client public JWK in <jwk>
//                             (cross-checked against `jose jwk exc`)

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>

#include <bearssl.h>

#include "tang_core.h"
#include "host_config.h"

using namespace esphome::tang;

static int multiply(uint8_t point[P256_POINT_LEN]) {
  return br_ec_p256_m15.mul(point, P256_POINT_LEN, KEY_D, sizeof(KEY_D), BR_EC_secp256r1) ? 0 : -1;
}

static std::string response(int status, const char *type, const std::string &body) {
  char head[160];
  snprintf(head, sizeof(head), "HTTP/1.1 %d X\r\nContent-Type: %s\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n",
           status, type, body.size());
  return head + body;
}

static std::string handle(const std::string &buf, bool *complete) {
  HttpRequest req;
  *complete = true;
  switch (parse_http_request(buf, req)) {
    case ParseResult::INCOMPLETE:
      *complete = false;
      return "";
    case ParseResult::TOO_LARGE:
      return response(413, "text/plain", "too large\n");
    case ParseResult::BAD_REQUEST:
      return response(400, "text/plain", "bad request\n");
    case ParseResult::NOT_IMPLEMENTED:
      return response(501, "text/plain", "no\n");
    case ParseResult::COMPLETE:
      break;
  }
  std::string kid;
  switch (route_request(req, kid)) {
    case Route::ADV:
      fprintf(stderr, "GET %s -> 200\n", req.path.c_str());
      return response(200, "application/jose+json", ADV);
    case Route::METHOD_NOT_ALLOWED:
      return response(405, "text/plain", "method\n");
    case Route::NOT_FOUND:
      return response(404, "text/plain", "not found\n");
    case Route::REC:
      break;
  }
  if (kid != KID_SHA256 && kid != KID_SHA1) {
    fprintf(stderr, "POST /rec/%s -> 404\n", kid.c_str());
    return response(404, "text/plain", "unknown kid\n");
  }
  uint8_t point[P256_POINT_LEN];
  const char *reason = parse_client_jwk(buf.data() + req.body_offset, req.content_length, point);
  if (reason != nullptr) {
    fprintf(stderr, "POST /rec/%s -> 400 %s\n", kid.c_str(), reason);
    return response(400, "text/plain", "bad jwk\n");
  }
  if (multiply(point) != 0) {
    fprintf(stderr, "POST /rec/%s -> 400 invalid point\n", kid.c_str());
    return response(400, "text/plain", "bad point\n");
  }
  std::string reply;
  format_reply_jwk(point, reply);
  fprintf(stderr, "POST /rec/%s -> 200\n", kid.c_str());
  return response(200, "application/jwk+json", reply);
}

static int serve(int port) {
  int srv = socket(AF_INET, SOCK_STREAM, 0);
  int one = 1;
  setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(srv, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) != 0 || listen(srv, 4) != 0) {
    perror("bind/listen");
    return 1;
  }
  for (;;) {
    int c = accept(srv, nullptr, nullptr);
    if (c < 0)
      continue;
    std::string buf, out;
    bool complete = false;
    char tmp[256];
    ssize_t n;
    while (!complete && (n = read(c, tmp, sizeof(tmp))) > 0) {
      buf.append(tmp, n);
      out = handle(buf, &complete);
    }
    if (complete)
      (void) !write(c, out.data(), out.size());
    close(c);
  }
}

static int exchange(const char *path) {
  std::ifstream f(path);
  std::stringstream ss;
  ss << f.rdbuf();
  std::string body = ss.str();
  uint8_t point[P256_POINT_LEN];
  const char *reason = parse_client_jwk(body.data(), body.size(), point);
  if (reason != nullptr) {
    fprintf(stderr, "parse: %s\n", reason);
    return 1;
  }
  if (multiply(point) != 0) {
    fprintf(stderr, "mul: invalid point\n");
    return 1;
  }
  std::string reply;
  format_reply_jwk(point, reply);
  puts(reply.c_str());
  return 0;
}

int main(int argc, char **argv) {
  if (argc == 3 && strcmp(argv[1], "--exc") == 0)
    return exchange(argv[2]);
  if (argc == 2)
    return serve(atoi(argv[1]));
  fprintf(stderr, "usage: %s <port> | --exc <client.jwk>\n", argv[0]);
  return 2;
}
