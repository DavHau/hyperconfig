import sys
import json
import os
import subprocess as sp
from argparse import ArgumentParser


def parse_args():
    parser = ArgumentParser()
    parser.add_argument(
        "attribute",
        help="The attribute to build",
        type=str,
    )
    parser.add_argument(
        "build_host",
        help="The host to build on",
        type=str,
    )
    # remaining args are passed to nix
    parser.add_argument(
        "nix_args",
        nargs="*",
        help="Arguments to pass to nix",
        default=[],
    )
    return parser.parse_args()


def main():
    args = parse_args()
    # call nix eval to get the drv path
    print("evaluating drvPath")
    drv_path = sp.run(
        [
            "nix",
            "eval",
            "--raw",
            f"{args.attribute}.drvPath",
        ],
        stdout=sp.PIPE,
        stderr=sys.stderr,
        check=True,
    ).stdout.strip().decode()
    # get outPath by calling nix show-derivation
    show_drv = sp.run(
        [
            "nix",
            "derivation",
            "show",
            f"{drv_path}^*",
        ],
        stdout=sp.PIPE,
        stderr=sys.stderr,
        check=True,
    ).stdout.strip().decode()
    drv = list(json.loads(show_drv).values())[0]
    outputs = {name: output["path"] for name, output in drv["outputs"].items()}
    # call nix build
    print(f"building {args.attribute} on {args.build_host}")
    sp.run(
        [
            "nix",
            "build",
            "--store",
            f"ssh-ng://{args.build_host}",
            "--eval-store",
            "auto",
            f"{drv_path}^*",
        ] + args.nix_args,
        check=True,
    )
    # call nix copy
    print(f"copying {args.attribute} from {args.build_host}")
    sp.run(
        [
            "nix",
            "copy",
            "--no-check-sigs",
            "--from",
            f"ssh-ng://{args.build_host}",
            *list(outputs.values()),
        ],
        check=True,
    )
    # create result symlinks for outputs
    for name, path in outputs.items():
        link_name = "result" if name == "out" else f"result-{name}"
        if os.path.lexists(link_name):
            os.unlink(link_name)
        os.symlink(path, link_name)


if __name__ == '__main__':
    main()
