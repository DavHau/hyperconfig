#pragma once

// Tang server component for the ESP8266. Structure (keys, kids, counters,
// logging) follows hansnielsen/tang-esphome (components/tang/tang.h),
// Copyright (c) 2026 Hans Nielsen, MIT License (see LICENSE in this directory).
//
// Why not web_server_base like upstream: on the ESP8266, ESPAsyncWebServer
// callbacks run in the SDK's system context, where yield() panics and a
// 100+ ms P-256 multiply would stall lwIP/WiFi underneath the callback. So
// this component runs its own tiny HTTP/1.x server on a dedicated port, polled
// from loop() (cont context), one connection at a time, and does the multiply
// right there.

#include "esphome/core/defines.h"

#ifdef USE_ESP8266

#include <memory>
#include <string>
#include <vector>

#include "esphome/components/socket/socket.h"
#include "esphome/core/component.h"

#ifdef USE_SENSOR
#include "esphome/components/sensor/sensor.h"
#endif

#include "tang_core.h"

namespace esphome {
namespace tang {

/// One P-256 exchange key ("deriveKey" in tang terms).
struct TangKey {
  /// Private scalar, 32 bytes big-endian, in PROGMEM.
  const uint8_t *d_progmem;
  /// RFC 7638 thumbprints this key answers to (clevis pins SHA-256).
  const char *kid_sha256;
  const char *kid_sha1;
};

class TangServer final : public Component {
 public:
  void set_port(uint16_t port) { this->port_ = port; }
  void add_key(const uint8_t *d_progmem, const char *kid_sha256, const char *kid_sha1) {
    this->keys_.push_back(TangKey{d_progmem, kid_sha256, kid_sha1});
  }
  /// The advertisement JWS (PROGMEM), signed at build time.
  void set_advertisement(const char *adv_progmem, size_t len) {
    this->adv_progmem_ = adv_progmem;
    this->adv_len_ = len;
  }
  void set_signing_thumbprint(const char *thp) { this->signing_thp_ = thp; }
#ifdef USE_SENSOR
  void set_multiply_time_sensor(sensor::Sensor *s) { this->multiply_time_sensor_ = s; }
  void set_rec_ok_sensor(sensor::Sensor *s) { this->rec_ok_sensor_ = s; }
  void set_rec_fail_sensor(sensor::Sensor *s) { this->rec_fail_sensor_ = s; }
#endif

  void setup() override;
  void loop() override;
  void dump_config() override;
  float get_setup_priority() const override { return setup_priority::AFTER_WIFI; }

 protected:
  void accept_();
  void read_();
  void handle_request_();
  void handle_rec_(const std::string &kid, const char *body, size_t len);
  /// Queues a complete response and switches to writing it.
  void respond_(int status, const char *content_type, const std::string &body);
  void write_();
  void close_client_();
  void count_(bool ok);
  const TangKey *find_key_(const std::string &kid) const;

  uint16_t port_{7654};
  std::vector<TangKey> keys_;
  const char *adv_progmem_{nullptr};
  size_t adv_len_{0};
  const char *signing_thp_{nullptr};

  std::unique_ptr<socket::ListenSocket> server_;
  std::unique_ptr<socket::Socket> client_;
  /// Request bytes so far, then the response being written; freed per connection.
  std::string rx_;
  std::string tx_;
  size_t tx_pos_{0};
  bool writing_{false};
  uint32_t client_start_{0};
  char peer_[socket::SOCKADDR_STR_LEN]{};

  uint32_t rec_ok_{0};
  uint32_t rec_fail_{0};
#ifdef USE_SENSOR
  sensor::Sensor *multiply_time_sensor_{nullptr};
  sensor::Sensor *rec_ok_sensor_{nullptr};
  sensor::Sensor *rec_fail_sensor_{nullptr};
#endif
};

}  // namespace tang
}  // namespace esphome

#endif  // USE_ESP8266
