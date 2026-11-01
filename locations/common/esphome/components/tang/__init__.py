"""Tang (clevis "tang" pin) key server for ESPHome on the ESP8266.

Serves tang's two endpoints on a dedicated TCP port:
  GET  /adv, /adv/, /adv/<thp>  the advertisement JWS, signed here at build time
  POST /rec/<kid>               the McCallum-Relyea (ECMR) exchange, on P-256

Ported from hansnielsen/tang-esphome (components/tang/__init__.py),
Copyright (c) 2026 Hans Nielsen, MIT License (see LICENSE in this directory).
ESP8266 changes: keys are imported as private JWKs (from secrets.yaml via
!secret) instead of being derived from a seed; the exchange key must be P-256
(BearSSL br_ec_p256_m15); the server runs on its own port instead of
web_server_base (see tang.h for why).
"""

import logging

import esphome.codegen as cg
from esphome.components import sensor, socket
import esphome.config_validation as cv
from esphome.const import (
    CONF_ID,
    CONF_PORT,
    ENTITY_CATEGORY_DIAGNOSTIC,
    ICON_TIMER,
    STATE_CLASS_MEASUREMENT,
    STATE_CLASS_TOTAL_INCREASING,
    UNIT_MILLISECOND,
)
from esphome.cpp_generator import RawExpression, RawStatement
from esphome.helpers import cpp_string_escape

from .jose import build_advertisement, thumbprints, validate_private_ec_jwk

CODEOWNERS = []
DEPENDENCIES = ["network"]
AUTO_LOAD = ["socket", "json", "sensor"]

CONF_EXCHANGE_KEY = "exchange_key"
CONF_OLD_KEYS = "old_keys"
CONF_SIGNING_KEY = "signing_key"
CONF_MULTIPLY_TIME = "multiply_time"
CONF_REC_OK = "rec_ok"
CONF_REC_FAIL = "rec_fail"

_LOGGER = logging.getLogger(__name__)

tang_ns = cg.esphome_ns.namespace("tang")
TangServer = tang_ns.class_("TangServer", cg.Component)


def _validate_exchange_jwk(value):
    try:
        jwk, crv, d = validate_private_ec_jwk(value)
    except ValueError as err:
        raise cv.Invalid(str(err)) from err
    if crv != "P-256":
        # BearSSL's P-256-only m15 backend is what keeps /rec fast on the
        # ESP8266; P-521 (tangd-keygen's default) would take seconds per unlock
        # with the soft watchdog armed.
        raise cv.Invalid(
            f"The exchange key must be on P-256 on the ESP8266, got {crv}. "
            "Generate one with modules/nixos/esphome-secrets.nix (clan vars)"
        )
    return {"jwk": jwk, "d": d, "kids": thumbprints(crv, jwk["x"], jwk["y"])}


def _validate_signing_jwk(value):
    try:
        jwk, _crv, _d = validate_private_ec_jwk(value)
    except ValueError as err:
        raise cv.Invalid(str(err)) from err
    return jwk


def _validate_config(config):
    seen = set()
    for key in [config[CONF_EXCHANGE_KEY]] + config[CONF_OLD_KEYS]:
        for kid in key["kids"]:
            if kid in seen:
                raise cv.Invalid(f"Duplicate exchange key, thumbprint {kid} is used twice")
            seen.add(kid)
    return config


def _counter_schema(icon):
    return sensor.sensor_schema(
        icon=icon,
        accuracy_decimals=0,
        state_class=STATE_CLASS_TOTAL_INCREASING,
        entity_category=ENTITY_CATEGORY_DIAGNOSTIC,
    )


CONFIG_SCHEMA = cv.All(
    cv.Schema(
        {
            cv.GenerateID(): cv.declare_id(TangServer),
            # Not 80: web_server owns that, and its callbacks run in SDK system
            # context where the multiply must not run.
            cv.Optional(CONF_PORT, default=7654): cv.port,
            # Private JWKs as JSON strings; sensitive() keeps 'd' out of dumps.
            cv.Required(CONF_EXCHANGE_KEY): cv.sensitive(_validate_exchange_jwk),
            cv.Required(CONF_SIGNING_KEY): cv.sensitive(_validate_signing_jwk),
            # Retired exchange keys: still answered on /rec, no longer advertised.
            cv.Optional(CONF_OLD_KEYS, default=[]): cv.ensure_list(
                cv.sensitive(_validate_exchange_jwk)
            ),
            cv.Optional(CONF_MULTIPLY_TIME): sensor.sensor_schema(
                unit_of_measurement=UNIT_MILLISECOND,
                icon=ICON_TIMER,
                accuracy_decimals=1,
                state_class=STATE_CLASS_MEASUREMENT,
                entity_category=ENTITY_CATEGORY_DIAGNOSTIC,
            ),
            cv.Optional(CONF_REC_OK): _counter_schema("mdi:lock-open-check"),
            cv.Optional(CONF_REC_FAIL): _counter_schema("mdi:lock-alert"),
        }
    ).extend(cv.COMPONENT_SCHEMA),
    _validate_config,
    cv.only_on_esp8266,
    cv.only_with_arduino,
    # One listener, plus the one connection served at a time.
    socket.consume_sockets(1, "tang", socket.SocketType.TCP_LISTEN),
    socket.consume_sockets(1, "tang"),
)


def _progmem_bytes(name, data):
    body = ", ".join(f"0x{b:02X}" for b in data)
    return RawStatement(f"static const uint8_t {name}[{len(data)}] PROGMEM = {{{body}}};")


async def to_code(config):
    var = cg.new_Pvariable(config[CONF_ID])
    await cg.register_component(var, config)
    cg.add(var.set_port(config[CONF_PORT]))

    exchange = config[CONF_EXCHANGE_KEY]
    # The advertised key first: find_key_() and dump_config() list it first.
    for index, key in enumerate([exchange] + config[CONF_OLD_KEYS]):
        name = f"tang_key{index}_d"
        cg.add_global(_progmem_bytes(name, key["d"]))
        kid_sha256, kid_sha1 = key["kids"]
        cg.add(var.add_key(RawExpression(name), kid_sha256, kid_sha1))

    # Only the current exchange key is advertised; that is what makes old_keys a
    # retirement list rather than a second live key. A fresh ECDSA signature per
    # build is fine: clevis checks it against the verify key, not byte-for-byte.
    signing = config[CONF_SIGNING_KEY]
    adv = build_advertisement([exchange["jwk"]], signing)
    cg.add_global(
        RawStatement(f"static const char tang_adv[] PROGMEM = {cpp_string_escape(adv)};")
    )
    cg.add(var.set_advertisement(RawExpression("tang_adv"), len(adv)))

    # What `clevis encrypt tang` shows at bind time ("thp"). Logged here and in
    # the device's dump_config().
    thp = thumbprints(signing["crv"], signing["x"], signing["y"])[0]
    _LOGGER.info("tang advertisement signing key thumbprint: %s", thp)
    cg.add(var.set_signing_thumbprint(thp))

    if conf := config.get(CONF_MULTIPLY_TIME):
        cg.add(var.set_multiply_time_sensor(await sensor.new_sensor(conf)))
    if conf := config.get(CONF_REC_OK):
        cg.add(var.set_rec_ok_sensor(await sensor.new_sensor(conf)))
    if conf := config.get(CONF_REC_FAIL):
        cg.add(var.set_rec_fail_sensor(await sensor.new_sensor(conf)))
