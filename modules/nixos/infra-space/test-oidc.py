"""A loopback OIDC issuer for the infra-space test: discovery and JWKS for
hermes' self-hosted provider, and /mint, a signed ID token for the
dashboard's allowed group (a session as Dave's, without pocket-id).

    test-oidc.py <port> <client id> <group>
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa
from jwt.algorithms import RSAAlgorithm

port, client_id, group = int(sys.argv[1]), sys.argv[2], sys.argv[3]
issuer = f"http://127.0.0.1:{port}"
key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
jwk = json.loads(RSAAlgorithm.to_jwk(key.public_key()))
jwk.update(kid="test", use="sig", alg="RS256")


class Handler(BaseHTTPRequestHandler):
    def _json(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/.well-known/openid-configuration":
            self._json({
                "issuer": issuer,
                "authorization_endpoint": f"{issuer}/authorize",
                "token_endpoint": f"{issuer}/token",
                "jwks_uri": f"{issuer}/jwks",
            })
        elif self.path == "/jwks":
            self._json({"keys": [jwk]})
        elif self.path == "/mint":
            now = int(time.time())
            token = jwt.encode(
                {"iss": issuer, "aud": client_id, "sub": "dave", "email": "dave@test",
                 "groups": [group], "iat": now, "exp": now + 600},
                key, algorithm="RS256", headers={"kid": "test"})
            body = token.encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()


HTTPServer(("127.0.0.1", port), Handler).serve_forever()
