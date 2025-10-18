#!/usr/bin/env python3

from subprocess import run
import argparse

def make_config(
    privatekey: str,
    publickey: str,
    prefix: str,
    suffix: str,
    endpoint: str,
    ipv4_address: str = "",
    port: int = 51820,
) -> str:
    return f"""[Interface]
PrivateKey = {privatekey}
Address = {prefix}:{suffix}
Address = {ipv4_address}
DNS = 1.1.1.1, 8.8.8.8
[Peer]
PublicKey = {publickey}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = {endpoint}:{port}
PersistentKeepalive = 25
"""

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Get WireGuard configuration for an external peer.")
    parser.add_argument("peer", type=str, help="The name of the WireGuard peer.")
    parser.add_argument("controller", type=str, help="The name of the controller.")
    parser.add_argument("instance", type=str, help="The instance name.")
    parser.add_argument("endpoint", type=str, nargs="?", default="", help="The endpoint for the WireGuard peer.")
    parser.add_argument("--ipv4-address", type=str, default="", help="The IPv4 address for the WireGuard peer (optional).")
    parser.add_argument("--port", type=int, default=51820, help="The port for the WireGuard peer (default: 51820).")
    return parser.parse_args()

def main() -> None:
    args = parse_args()
    privatekey_cmd = ["clan", "vars", "get", args.controller, f"wireguard-network-{args.instance}-external-peer-{args.peer}/privatekey"]
    privatekey = run(privatekey_cmd, capture_output=True, text=True, check=True).stdout.strip()
    publickey_controller_cmd = ["clan", "vars", "get", args.controller, f"wireguard-keys-{args.instance}/publickey"]
    publickey_controller = run(publickey_controller_cmd, capture_output=True, text=True, check=True).stdout.strip()
    suffix_cmd = ["clan", "vars", "get", args.controller, f"wireguard-network-{args.instance}-external-peer-{args.peer}/suffix"]
    suffix = run(suffix_cmd, capture_output=True, text=True, check=True).stdout.strip()
    prefix_cmd = ["clan", "vars", "get", args.controller, f"wireguard-network-{args.instance}/prefix"]
    prefix = run(prefix_cmd, capture_output=True, text=True, check=True).stdout.strip()
    print(make_config(privatekey, publickey_controller, prefix, suffix, args.endpoint, args.ipv4_address, args.port))

if __name__ == "__main__":
    main()
