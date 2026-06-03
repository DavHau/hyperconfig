#!/usr/bin/env python3

import os
import sys
from subprocess import run
import argparse
import json


def _ensure_clan_lib() -> None:
    """Make ``clan_lib`` importable when run as a plain executable.

    The system ``python3`` has no access to clan-cli's bundled ``clan_lib``.
    Locate the ``clan`` wrapper on ``PATH``, read the interpreter and
    site-package dirs baked into it, then re-exec this script under that
    interpreter with those dirs on ``PYTHONPATH``.
    """
    try:
        import clan_lib  # noqa: F401
        return
    except ModuleNotFoundError:
        pass

    if os.environ.get("_GWC_REEXEC") == "1":
        sys.exit("error: clan_lib still missing after re-exec; is clan-cli installed?")

    import re
    import shutil

    clan = shutil.which("clan")
    if clan is None:
        sys.exit("error: 'clan' not on PATH. Run inside `nix develop` or install clan-cli.")
    wrapper = os.path.join(os.path.dirname(os.path.realpath(clan)), ".clan-wrapped")
    try:
        src = open(wrapper, encoding="utf-8").read()
    except OSError as e:
        sys.exit(f"error: cannot read clan wrapper {wrapper}: {e}")

    lines = src.splitlines()
    if not lines or not lines[0].startswith("#!"):
        sys.exit(f"error: unexpected clan wrapper format: {wrapper}")
    interp = lines[0][2:].strip()
    site_dirs = re.findall(r"'(/nix/store/[^']*?site-packages)'", src)
    if not site_dirs:
        sys.exit(f"error: no site-packages found in clan wrapper: {wrapper}")

    env = dict(os.environ)
    env["_GWC_REEXEC"] = "1"
    existing = env.get("PYTHONPATH", "")
    env["PYTHONPATH"] = os.pathsep.join(site_dirs + ([existing] if existing else []))
    os.execve(interp, [interp, os.path.abspath(__file__), *sys.argv[1:]], env)


_ensure_clan_lib()

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

def get_wireguard_service_ids() -> list[str]:
    """Distributed-service ids for every WireGuard instance in the clan.

    The id is ``<input>-wireguard`` where ``<input>`` is the flake input the
    module came from (``<clan-core>`` when unset). A clan may run several
    wireguard instances sourced from different inputs (e.g. a vendored
    ``self`` copy alongside the upstream ``clan-core`` one), so collect all.
    """
    modules = flake.select("clan.inventory.instances.*.module")
    ids = {
        f'{module.get("input") or "<clan-core>"}-wireguard'
        for module in modules.values()
        if module.get("name") == "wireguard"
    }
    return sorted(ids)


def get_instances_data() -> dict:
    """Controller settings per instance: ``{instance: {controller: config}}``.

    Merged across all wireguard distributed-service ids.
    """
    data: dict = {}
    for service_id in get_wireguard_service_ids():
        data.update(
            flake.select(
                f'clan._services.allServices."{service_id}"'
                ".instances.*.roles.controller.machines.*.finalSettings.config"
            )
        )
    return data


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

    controller_config = instances_data[instance][controller]
    endpoint = controller_config["endpoint"]
    port = controller_config["port"]

    # Get peer-specific settings from instances_data
    peer_config = controller_config['externalPeers'][peer]
    allow_internet_access = peer_config.get('allowInternetAccess', True)

    # Get peer's IPv4 address (can be overridden by command line arg)
    peer_ipv4 = peer_config.get('ipv4', {}).get('address', '')
    ipv4_address = args.ipv4_address if args.ipv4_address else peer_ipv4

    # Get IPv4 network address from controller config (for AllowedIPs)
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
