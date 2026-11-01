// Tang server for the ESP8266, see tang.h. Request handling, logging and
// counters follow hansnielsen/tang-esphome (components/tang/tang.cpp),
// Copyright (c) 2026 Hans Nielsen, MIT License (see LICENSE in this directory);
// the mbedTLS multiply is replaced by BearSSL from the Arduino core.

#include "tang.h"

#ifdef USE_ESP8266

#include <cerrno>
#include <cstring>

#include <Arduino.h>
#include <StackThunk.h>
#include <bearssl/bearssl.h>

#include "esphome/core/application.h"
#include "esphome/core/hal.h"
#include "esphome/core/log.h"

// The multiply runs on the BearSSL secondary stack ("StackThunk", ~6.2 KB,
// heap-allocated) rather than the 4 KB cont stack loop() runs on:
// br_ec_p256_m15's p256_mul keeps six 240-byte Jacobian points plus window
// tables and temporaries on the stack (~2-2.5 KB), and ESPHome's loop() frames
// already sit on top of the cont stack. Overflowing cont silently corrupts the
// heap below it; the thunk stack is painted and canary-checked on return
// (stack_thunk_fatal_smashing) and its high-water mark is logged per request.
// It is allocated only for the duration of one multiply, so it costs no RAM
// while idle.
extern "C" {
uint32_t esphome_tang_p256_mul(uint8_t *point, const uint8_t *scalar);
uint32_t thunk_esphome_tang_p256_mul(uint8_t *point, const uint8_t *scalar);
}

uint32_t esphome_tang_p256_mul(uint8_t *point, const uint8_t *scalar) {
  // Returns 0 unless point is a valid point of the P-256 group (and the result
  // is not the point at infinity). That check is what stops invalid-curve
  // attacks; BearSSL's code is constant-time, so no blinding/RNG is needed.
  return br_ec_p256_m15.mul(point, esphome::tang::P256_POINT_LEN, scalar, esphome::tang::P256_COORD_LEN,
                            BR_EC_secp256r1);
}
make_stack_thunk(esphome_tang_p256_mul);

namespace esphome {
namespace tang {

static const char *const TAG = "tang";
static const char *const JWK_CONTENT_TYPE = "application/jwk+json";
static const char *const JWS_CONTENT_TYPE = "application/jose+json";
static const char *const TEXT_CONTENT_TYPE = "text/plain";
/// A connection gets this long to send its request and take the response.
static const uint32_t CLIENT_TIMEOUT_MS = 10000;
/// The thunk stack is one 6200-byte malloc; refuse (503) rather than let
/// stack_thunk_add_ref() abort() the device when the heap is fragmented.
static const uint32_t STACK_THUNK_MIN_BLOCK = 6200 + 256;

static const char *reason_phrase(int status) {
  switch (status) {
    case 200:
      return "OK";
    case 400:
      return "Bad Request";
    case 404:
      return "Not Found";
    case 405:
      return "Method Not Allowed";
    case 413:
      return "Payload Too Large";
    case 501:
      return "Not Implemented";
    case 503:
      return "Service Unavailable";
    default:
      return "Internal Server Error";
  }
}

void TangServer::setup() {
  this->server_ = socket::socket_ip_loop_monitored(SOCK_STREAM, 0);
  if (this->server_ == nullptr) {
    ESP_LOGE(TAG, "Could not create socket");
    this->mark_failed();
    return;
  }
  int enable = 1;
  this->server_->setsockopt(SOL_SOCKET, SO_REUSEADDR, &enable, sizeof(enable));
  this->server_->setblocking(false);

  struct sockaddr_storage addr;
  socklen_t sl = socket::set_sockaddr_any(reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr), this->port_);
  if (sl == 0 || this->server_->bind(reinterpret_cast<struct sockaddr *>(&addr), sl) != 0 ||
      this->server_->listen(2) != 0) {
    ESP_LOGE(TAG, "Could not listen on port %u (errno %d)", this->port_, errno);
    this->server_.reset();
    this->mark_failed();
    return;
  }

#ifdef USE_SENSOR
  // Publish zeroes so the counters read 0, not "unknown", before the first unlock.
  if (this->rec_ok_sensor_ != nullptr)
    this->rec_ok_sensor_->publish_state(0);
  if (this->rec_fail_sensor_ != nullptr)
    this->rec_fail_sensor_->publish_state(0);
#endif
}

void TangServer::dump_config() {
  ESP_LOGCONFIG(TAG,
                "Tang server:\n"
                "  Port: %u\n"
                "  Endpoints: GET /adv[/<thp>], POST /rec/<kid>\n"
                "  Advertisement: %u bytes",
                this->port_, static_cast<unsigned>(this->adv_len_));
  for (const auto &key : this->keys_) {
    ESP_LOGCONFIG(TAG,
                  "  Exchange key (P-256):\n"
                  "    kid (SHA-256): %s\n"
                  "    kid (SHA-1): %s",
                  key.kid_sha256, key.kid_sha1);
  }
  if (this->signing_thp_ != nullptr)
    ESP_LOGCONFIG(TAG, "  Signing thumbprint: %s", this->signing_thp_);
}

void TangServer::loop() {
  if (this->server_ == nullptr)
    return;
  if (this->client_ == nullptr) {
    if (!this->server_->ready())
      return;
    this->accept_();
    if (this->client_ == nullptr)
      return;
  }
  if (millis() - this->client_start_ > CLIENT_TIMEOUT_MS) {
    ESP_LOGW(TAG, "Connection from %s timed out", this->peer_);
    this->close_client_();
    return;
  }
  if (this->writing_) {
    this->write_();
  } else {
    this->read_();
  }
}

void TangServer::accept_() {
  struct sockaddr_storage addr;
  socklen_t addr_len = sizeof(addr);
  this->client_ = this->server_->accept_loop_monitored(reinterpret_cast<struct sockaddr *>(&addr), &addr_len);
  if (this->client_ == nullptr)
    return;
  int enable = 1;
  // With LWIP raw TCP, TCP_NODELAY is what makes write() push the segment out
  // right away instead of waiting for lwIP's timer.
  this->client_->setsockopt(IPPROTO_TCP, TCP_NODELAY, &enable, sizeof(enable));
  this->client_->setblocking(false);
  if (this->client_->getpeername_to(this->peer_) == 0)
    strcpy(this->peer_, "?");
  this->client_start_ = millis();
  this->writing_ = false;
  this->rx_.clear();
  this->rx_.reserve(384);
}

void TangServer::read_() {
  uint8_t buf[256];
  bool eof = false;
  // Drain until EWOULDBLOCK, per the socket ready() contract, but stop at the
  // size cap: the parser then answers 413 and the connection is dropped.
  while (this->rx_.size() <= MAX_REQUEST_SIZE) {
    ssize_t n = this->client_->read(buf, sizeof(buf));
    if (n > 0) {
      this->rx_.append(reinterpret_cast<const char *>(buf), n);
      continue;
    }
    if (n == 0) {
      eof = true;
      break;
    }
    if (errno == EWOULDBLOCK || errno == EAGAIN)
      break;
    ESP_LOGW(TAG, "Read from %s failed (errno %d)", this->peer_, errno);
    this->close_client_();
    return;
  }

  HttpRequest req;
  switch (parse_http_request(this->rx_, req)) {
    case ParseResult::INCOMPLETE:
      if (eof)
        this->close_client_();
      return;
    case ParseResult::TOO_LARGE:
      ESP_LOGW(TAG, "Request from %s too large", this->peer_);
      this->respond_(413, TEXT_CONTENT_TYPE, "Request too large\n");
      return;
    case ParseResult::BAD_REQUEST:
      ESP_LOGW(TAG, "Malformed HTTP request from %s", this->peer_);
      this->respond_(400, TEXT_CONTENT_TYPE, "Bad request\n");
      return;
    case ParseResult::NOT_IMPLEMENTED:
      ESP_LOGW(TAG, "Unsupported transfer encoding from %s", this->peer_);
      this->respond_(501, TEXT_CONTENT_TYPE, "Send a Content-Length\n");
      return;
    case ParseResult::COMPLETE:
      break;
  }

  std::string kid;
  switch (route_request(req, kid)) {
    case Route::ADV: {
      ESP_LOGI(TAG, "GET %s from %s -> 200, advertisement (%u bytes)", req.path.c_str(), this->peer_,
               static_cast<unsigned>(this->adv_len_));
      std::string adv(this->adv_len_, '\0');
      memcpy_P(&adv[0], this->adv_progmem_, this->adv_len_);
      this->respond_(200, JWS_CONTENT_TYPE, adv);
      return;
    }
    case Route::REC:
      this->handle_rec_(kid, this->rx_.data() + req.body_offset, req.content_length);
      return;
    case Route::METHOD_NOT_ALLOWED:
      ESP_LOGW(TAG, "%s %s from %s -> 405", req.method.c_str(), req.path.c_str(), this->peer_);
      this->respond_(405, TEXT_CONTENT_TYPE, "Method not allowed\n");
      return;
    case Route::NOT_FOUND:
      ESP_LOGW(TAG, "%s %s from %s -> 404", req.method.c_str(), req.path.c_str(), this->peer_);
      this->respond_(404, TEXT_CONTENT_TYPE, "Not found\n");
      return;
  }
}

const TangKey *TangServer::find_key_(const std::string &kid) const {
  for (const auto &key : this->keys_) {
    if (kid == key.kid_sha256 || kid == key.kid_sha1)
      return &key;
  }
  return nullptr;
}

void TangServer::handle_rec_(const std::string &kid, const char *body, size_t len) {
  const TangKey *key = this->find_key_(kid);
  if (key == nullptr) {
    ESP_LOGW(TAG, "POST /rec/%s from %s -> 404, no such key", kid.c_str(), this->peer_);
    this->count_(false);
    this->respond_(404, TEXT_CONTENT_TYPE, "Unknown key ID\n");
    return;
  }

  uint8_t point[P256_POINT_LEN];
  const char *reason = parse_client_jwk(body, len, point);
  if (reason != nullptr) {
    ESP_LOGW(TAG, "POST /rec/%s from %s -> 400, %s", kid.c_str(), this->peer_, reason);
    this->count_(false);
    this->respond_(400, TEXT_CONTENT_TYPE, "Bad request JWK\n");
    return;
  }

  uint32_t free_heap = ESP.getFreeHeap();
  uint32_t max_block = ESP.getMaxFreeBlockSize();
  if (stack_thunk_get_refcnt() == 0 && max_block < STACK_THUNK_MIN_BLOCK) {
    ESP_LOGE(TAG, "POST /rec/%s from %s -> 503, largest free heap block %u B < %u B for the EC stack", kid.c_str(),
             this->peer_, static_cast<unsigned>(max_block), static_cast<unsigned>(STACK_THUNK_MIN_BLOCK));
    this->count_(false);
    this->respond_(503, TEXT_CONTENT_TYPE, "Out of memory, retry\n");
    return;
  }

  uint8_t d[P256_COORD_LEN];
  memcpy_P(d, key->d_progmem, sizeof(d));
  stack_thunk_add_ref();
  App.feed_wdt();
  uint32_t started = micros();
  uint32_t ok = thunk_esphome_tang_p256_mul(point, d);
  uint32_t elapsed_us = micros() - started;
  App.feed_wdt();
  uint32_t stack_used = stack_thunk_get_max_usage();
  stack_thunk_del_ref();
  // Do not leave the private scalar lying around on the stack.
  volatile uint8_t *wipe = d;
  for (size_t i = 0; i < sizeof(d); i++)
    wipe[i] = 0;

  if (!ok) {
    // Not a point on P-256: refusing it is what stops invalid-curve attacks
    // from leaking the private key one query at a time.
    ESP_LOGW(TAG, "POST /rec/%s from %s -> 400, not a valid P-256 point (%u us)", kid.c_str(), this->peer_,
             static_cast<unsigned>(elapsed_us));
    this->count_(false);
    this->respond_(400, TEXT_CONTENT_TYPE, "Bad request point\n");
    return;
  }

  std::string reply;
  reply.reserve(110);
  format_reply_jwk(point, reply);
  // Loud on purpose: every line here is a volume being unlocked somewhere.
  ESP_LOGI(TAG,
           "POST /rec/%s from %s -> 200, P-256 multiply %u us (thunk stack %u B, heap free %u B, max block %u B, "
           "CPU %u MHz)",
           kid.c_str(), this->peer_, static_cast<unsigned>(elapsed_us), static_cast<unsigned>(stack_used),
           static_cast<unsigned>(free_heap), static_cast<unsigned>(max_block),
           static_cast<unsigned>(ESP.getCpuFreqMHz()));
#ifdef USE_SENSOR
  if (this->multiply_time_sensor_ != nullptr)
    this->multiply_time_sensor_->publish_state(elapsed_us / 1000.0f);
#endif
  this->count_(true);
  this->respond_(200, JWK_CONTENT_TYPE, reply);
}

void TangServer::count_(bool ok) {
#ifdef USE_SENSOR
  if (ok) {
    this->rec_ok_++;
    if (this->rec_ok_sensor_ != nullptr)
      this->rec_ok_sensor_->publish_state(this->rec_ok_);
  } else {
    this->rec_fail_++;
    if (this->rec_fail_sensor_ != nullptr)
      this->rec_fail_sensor_->publish_state(this->rec_fail_);
  }
#endif
}

void TangServer::respond_(int status, const char *content_type, const std::string &body) {
  // The request buffer is done with; give its heap back before building the reply.
  std::string().swap(this->rx_);
  char head[160];
  int head_len = snprintf(head, sizeof(head),
                          "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %u\r\nConnection: close\r\n\r\n",
                          status, reason_phrase(status), content_type, static_cast<unsigned>(body.size()));
  this->tx_.reserve(head_len + body.size());
  this->tx_.assign(head, head_len);
  this->tx_.append(body);
  this->tx_pos_ = 0;
  this->writing_ = true;
  this->write_();
}

void TangServer::write_() {
  while (this->tx_pos_ < this->tx_.size()) {
    ssize_t n = this->client_->write(this->tx_.data() + this->tx_pos_, this->tx_.size() - this->tx_pos_);
    if (n > 0) {
      this->tx_pos_ += n;
      continue;
    }
    if (n < 0 && (errno == EWOULDBLOCK || errno == EAGAIN))
      return;  // send buffer full; continue on the next loop()
    ESP_LOGW(TAG, "Write to %s failed (errno %d)", this->peer_, errno);
    break;
  }
  this->close_client_();
}

void TangServer::close_client_() {
  if (this->client_ != nullptr) {
    this->client_->close();
    this->client_.reset();
  }
  std::string().swap(this->rx_);
  std::string().swap(this->tx_);
  this->tx_pos_ = 0;
  this->writing_ = false;
}

}  // namespace tang
}  // namespace esphome

#endif  // USE_ESP8266
