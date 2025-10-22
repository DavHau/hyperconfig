#!/usr/bin/env python3

from subprocess import run
import argparse
import json

from clan_lib.flake import Flake
from clan_lib.nix import nix_shell

flake = Flake(".")

def make_config(
    privatekey: str,
    publickey: str,
    prefix: str,
    suffix: str,
    endpoint: str,
    ipv4_address: str = "",
    port: int = 51820,
    allow_internet_access: bool = True,
    ipv4_network: str = "",
) -> str:
    if allow_internet_access:
        allowed_ips = "0.0.0.0/0, ::/0"
    else:
        # Only route traffic to the VPN network, not all traffic
        allowed_ips_parts = []
        if ipv4_network:
            allowed_ips_parts.append(ipv4_network)
        if prefix:
            allowed_ips_parts.append(f"{prefix}::/56")
        allowed_ips = ", ".join(allowed_ips_parts)

    return f"""[Interface]
PrivateKey = {privatekey}
Address = {prefix}:{suffix}
Address = {ipv4_address}
DNS = 1.1.1.1, 8.8.8.8
[Peer]
PublicKey = {publickey}
AllowedIPs = {allowed_ips}
Endpoint = {endpoint}:{port}
PersistentKeepalive = 25
"""

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Get WireGuard configuration for an external peer.")
    parser.add_argument("instance", type=str, nargs='?', help="The instance name.")
    parser.add_argument("controller", type=str, nargs='?', help="The name of the controller.")
    parser.add_argument("peer", type=str, nargs='?', help="The name of the WireGuard peer.")
    parser.add_argument("--ipv4-address", type=str, default="", help="The IPv4 address for the WireGuard peer (optional).")
    return parser.parse_args()


def select_from_list(items: list[str], prompt: str, single_item_message: str) -> str:
    """Display a list of items and prompt the user to select one."""
    if not items:
        raise ValueError("No items to select from")

    if len(items) == 1:
        print(f"{single_item_message}: {items[0]}")
        return items[0]

    print(f"\n{prompt}")
    for i, item in enumerate(items, 1):
        print(f"  {i}. {item}")

    while True:
        try:
            choice = input(f"\nSelect (1-{len(items)}): ").strip()
            index = int(choice) - 1
            if 0 <= index < len(items):
                return items[index]
            print(f"Please enter a number between 1 and {len(items)}")
        except ValueError:
            print("Invalid input. Please enter a number.")
        except (KeyboardInterrupt, EOFError):
            print("\nExiting...")
            exit(1)

def get_endpoint(controller: str, instance: str) -> str:
    endpoint = flake.select(
        f"clan.clanInternals.inventoryClass.distributedServices.servicesEval.config.mappedServices.\"<clan-core>-wireguard\".instances.{instance}.roles.controller.machines.{controller}.finalSettings.config.endpoint"
    )
    return endpoint

def get_port(controller: str, instance: str) -> int:
    port_str = flake.select(
        f"clan.clanInternals.inventoryClass.distributedServices.servicesEval.config.mappedServices.\"<clan-core>-wireguard\".instances.{instance}.roles.controller.machines.{controller}.finalSettings.config.port"
    )
    return int(port_str)

def get_instances_data() -> dict:
    """Get the complete instances data structure."""
    return flake.select(
        "clan.clanInternals.inventoryClass.distributedServices.servicesEval.config.mappedServices.\"<clan-core>-wireguard\".instances.*.roles.controller.machines.*.finalSettings.config"
    )


def get_controllers_for_instance(instances_data: dict, instance: str) -> list[str]:
    """Get list of controllers for a given instance."""
    if instance not in instances_data:
        raise ValueError(f"Instance '{instance}' not found")
    return sorted(instances_data[instance].keys())


def get_peers_for_controller(instances_data: dict, instance: str, controller: str) -> list[str]:
    """Get list of external peers for a given controller and instance."""
    if instance not in instances_data:
        raise ValueError(f"Instance '{instance}' not found")
    if controller not in instances_data[instance]:
        raise ValueError(f"Controller '{controller}' not found in instance '{instance}'")
    external_peers = instances_data[instance][controller].get("externalPeers", {})
    return sorted(external_peers.keys())

def main() -> None:
    args = parse_args()

    # Get instances data once
    instances_data = get_instances_data()

    # Select instance (use arg if provided, otherwise prompt)
    if args.instance:
        instance = args.instance
    else:
        instance_list = sorted(instances_data.keys())
        instance = select_from_list(
            instance_list,
            "Available WireGuard instances:",
            "Only one WireGuard instance available"
        )

    # Select controller (use arg if provided, otherwise prompt)
    if args.controller:
        controller = args.controller
    else:
        controller_list = get_controllers_for_instance(instances_data, instance)
        controller = select_from_list(
            controller_list,
            f"Available controllers for instance '{instance}':",
            f"Only one controller available for instance '{instance}'"
        )

    # Select peer (use arg if provided, otherwise prompt)
    if args.peer:
        peer = args.peer
    else:
        peer_list = get_peers_for_controller(instances_data, instance, controller)
        peer = select_from_list(
            peer_list,
            f"Available external peers for controller '{controller}':",
            f"Only one external peer available for controller '{controller}'"
        )

    # Get configuration values
    privatekey_cmd = ["clan", "vars", "get", controller, f"wireguard-network-{instance}-external-peer-{peer}/privatekey"]
    privatekey = run(privatekey_cmd, capture_output=True, text=True, check=True).stdout.strip()
    publickey_controller_cmd = ["clan", "vars", "get", controller, f"wireguard-keys-{instance}/publickey"]
    publickey_controller = run(publickey_controller_cmd, capture_output=True, text=True, check=True).stdout.strip()
    suffix_cmd = ["clan", "vars", "get", controller, f"wireguard-network-{instance}-external-peer-{peer}/suffix"]
    suffix = run(suffix_cmd, capture_output=True, text=True, check=True).stdout.strip()
    prefix_cmd = ["clan", "vars", "get", controller, f"wireguard-network-{instance}/prefix"]
    prefix = run(prefix_cmd, capture_output=True, text=True, check=True).stdout.strip()

    endpoint = get_endpoint(controller, instance)
    port = get_port(controller, instance)

    # Get peer-specific settings from instances_data
    peer_config = instances_data[instance][controller]['externalPeers'][peer]
    allow_internet_access = peer_config.get('allowInternetAccess', True)

    # Get peer's IPv4 address (can be overridden by command line arg)
    peer_ipv4 = peer_config.get('ipv4', {}).get('address', '')
    ipv4_address = args.ipv4_address if args.ipv4_address else peer_ipv4

    # Get IPv4 network address from controller config (for AllowedIPs)
    controller_config = instances_data[instance][controller]
    ipv4_network = controller_config.get('ipv4', {}).get('address', '')

    config = make_config(
        privatekey,
        publickey_controller,
        prefix,
        suffix,
        endpoint,
        ipv4_address,
        port,
        allow_internet_access,
        ipv4_network,
    )

    print()
    print("Configuration:")
    print()
    print(config)
    print()

    # Generate QR code
    print("QR Code:")
    cmd = nix_shell(["qrencode"], ["qrencode", "-s", "2", "-m", "2", "-t", "utf8"])
    qr_result = run(
        cmd,
        input=config,
        capture_output=True,
        text=True,
        check=True
    )
    print(qr_result.stdout)

if __name__ == "__main__":
    main()
