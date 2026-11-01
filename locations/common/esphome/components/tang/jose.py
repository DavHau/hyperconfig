"""JOSE helpers for the tang component's build-time key handling.

Ported from hansnielsen/tang-esphome (components/tang/jose.py),
Copyright (c) 2026 Hans Nielsen, MIT License (see LICENSE in this directory).
Changes: dropped the seed/HKDF derivation (keys are imported as private JWKs
from secrets.yaml instead), dropped the mbedTLS group ids.

Kept free of ESPHome imports so tests/tang can exercise it on the host.
"""

import base64
import hashlib
import json
from typing import NamedTuple

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature


class Curve(NamedTuple):
    """What we need to know about one JOSE curve."""

    alg: str
    """JWS signing algorithm paired with this curve by RFC 7518."""
    hash_cls: type
    curve_cls: type

    @property
    def coord_len(self):
        """Coordinate size in bytes, which is what a JWK's x, y and d encode to."""
        return (self.curve_cls().key_size + 7) // 8


CURVES = {
    "P-256": Curve("ES256", hashes.SHA256, ec.SECP256R1),
    "P-384": Curve("ES384", hashes.SHA384, ec.SECP384R1),
    "P-521": Curve("ES512", hashes.SHA512, ec.SECP521R1),
}


def b64e(data):
    """Encode as base64url without padding, the way JOSE writes it."""
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def b64d(value):
    """Decode base64url strictly: no '+' or '/', nothing outside the alphabet.

    A JWK member spelled with standard-base64 characters is not the one clevis
    hashes, so it has to fail rather than decode to a point that is advertised
    under some other key ID. Raises ValueError on bad input.
    """
    if "+" in value or "/" in value:
        raise ValueError("standard base64 characters in a base64url value")
    return base64.b64decode(
        value + "=" * (-len(value) % 4), altchars=b"-_", validate=True
    )


def thumbprints(crv, x, y):
    """RFC 7638 thumbprints (SHA-256, SHA-1) of the public half.

    Only the required members are hashed, so the 'alg' and 'key_ops' the
    advertisement carries do not change the key ID. clevis pins the SHA-256
    one; SHA-1 is accepted for pins made by older clevis versions.
    """
    required = json.dumps(
        {"crv": crv, "kty": "EC", "x": x, "y": y},
        separators=(",", ":"),
        sort_keys=True,
    ).encode()
    return [
        b64e(hashlib.sha256(required).digest()),
        b64e(hashlib.sha1(required).digest()),
    ]


def private_key_from_jwk(jwk):
    return ec.derive_private_key(
        int.from_bytes(b64d(jwk["d"]), "big"), CURVES[jwk["crv"]].curve_cls()
    )


def public_member(jwk, alg, key_ops):
    return {
        "alg": alg,
        "crv": jwk["crv"],
        "key_ops": key_ops,
        "kty": "EC",
        "x": jwk["x"],
        "y": jwk["y"],
    }


def build_advertisement(exchange, signing):
    """The JWS tang serves from /adv: a JWK Set of public keys, signed.

    clevis verifies it with a 'verify' key from this very payload and then
    encrypts against the first 'deriveKey' key, so both have to be in the set.
    """
    curve = CURVES[signing["crv"]]
    coord_len, alg = curve.coord_len, curve.alg
    jwks = {
        "keys": [public_member(k, "ECMR", ["deriveKey"]) for k in exchange]
        + [public_member(signing, alg, ["verify"])]
    }
    payload = b64e(json.dumps(jwks, separators=(",", ":")).encode())
    protected = b64e(
        json.dumps({"alg": alg, "cty": "jwk-set+json"}, separators=(",", ":")).encode()
    )

    der = private_key_from_jwk(signing).sign(
        f"{protected}.{payload}".encode(), ec.ECDSA(curve.hash_cls())
    )
    # JOSE wants the raw R||S pair, not the DER structure cryptography returns.
    r, s = decode_dss_signature(der)
    signature = b64e(r.to_bytes(coord_len, "big") + s.to_bytes(coord_len, "big"))

    return json.dumps(
        {
            "payload": payload,
            "signatures": [{"protected": protected, "signature": signature}],
        },
        separators=(",", ":"),
    )


def validate_private_ec_jwk(value):
    """Parse and check a private EC JWK given as a JSON string.

    Returns (jwk, crv, d) with x and y re-encoded at full width. Raises
    ValueError with a human-readable message on any problem, including the worst
    one: a 'd' that does not match (x, y), which would build and advertise fine
    but could never unlock anything bound to the advertised point.
    """
    if not isinstance(value, str):
        raise ValueError("Key must be a JWK given as a JSON string")
    try:
        jwk = json.loads(value)
    except ValueError as err:
        raise ValueError(f"Key is not valid JSON: {err}") from err
    if not isinstance(jwk, dict):
        raise ValueError("Key must be a JWK object")
    if jwk.get("kty") != "EC":
        raise ValueError("Only EC keys are supported (kty must be 'EC')")
    crv = jwk.get("crv")
    if crv not in CURVES:
        raise ValueError(f"Unsupported curve {crv!r}, expected one of {', '.join(CURVES)}")
    coord_len = CURVES[crv].coord_len

    for member in ("x", "y", "d"):
        if not isinstance(jwk.get(member), str):
            raise ValueError(
                f"Key is missing the '{member}' member; a *private* JWK is required "
                "(see modules/nixos/esphome-secrets.nix)"
            )
    try:
        d = b64d(jwk["d"])
        coords = {m: b64d(jwk[m]) for m in ("x", "y")}
    except ValueError as err:
        raise ValueError(f"Key member is not valid base64url: {err}") from err
    if not 0 < len(d) <= coord_len:
        raise ValueError(f"Private scalar 'd' must be 1..{coord_len} bytes, got {len(d)}")
    for member, raw in coords.items():
        if len(raw) > coord_len:
            raise ValueError(f"Coordinate '{member}' must be at most {coord_len} bytes")
        # Re-encode at full width: a stripped leading zero is the same point but
        # a different thumbprint, i.e. a kid nobody pinned.
        jwk[member] = b64e(raw.rjust(coord_len, b"\0"))

    curve_cls = CURVES[crv].curve_cls
    try:
        public = ec.EllipticCurvePublicNumbers(
            int.from_bytes(coords["x"], "big"), int.from_bytes(coords["y"], "big"), curve_cls()
        ).public_key()
    except ValueError:
        raise ValueError(f"Point (x, y) is not on curve {crv}") from None
    try:
        derived = ec.derive_private_key(int.from_bytes(d, "big"), curve_cls())
    except ValueError:
        raise ValueError(f"Private scalar 'd' is out of range for {crv}") from None
    if derived.public_key().public_numbers() != public.public_numbers():
        raise ValueError("Private scalar 'd' does not match the public key (x, y)")
    return jwk, crv, d.rjust(coord_len, b"\0")
