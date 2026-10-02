from argparse import ArgumentParser
from typing import TextIO
from pathlib import Path
from io import StringIO
import sys
import json
import docker


def load_entries(io: TextIO):
    entries = {}
    for line in io:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        path = obj["path"]
        del obj["path"]
        entries[path] = obj
    return entries


def do_compare(nix2container: dict, nix_snapshotter: dict):
    missing_in_nix2container = []
    missing_in_nix_snapshotter = []
    differing_files = []

    for k, v in nix2container.items():
        if not k in nix_snapshotter:
            missing_in_nix_snapshotter.append(k)
    for k, v in nix_snapshotter.items():
        if not k in nix2container:
            missing_in_nix2container.append(k)

    for k, v0 in nix2container.items():
        if not k in nix_snapshotter:
            continue

        v1 = nix_snapshotter[k]
        if v0 != v1:
            differing_files.append(k)

    if len(missing_in_nix_snapshotter) > 0:
        print(
            "Files present in nix2container image but missing in nix-snapshotter image:",
            file=sys.stderr,
        )
        for path in missing_in_nix_snapshotter:
            print(f"  {path}", file=sys.stderr)

    if len(missing_in_nix2container) > 0:
        print(
            "Files present in nix-snapshotter image but missing in nix2container image:",
            file=sys.stderr,
        )
        for path in missing_in_nix2container:
            print(f"  {path}", file=sys.stderr)

    if len(differing_files) > 0:
        print(
            "Files that differ between nix2container and nix-snapshotter images:",
            file=sys.stderr,
        )
        for path in differing_files:
            print(path)


def main():
    parser = ArgumentParser()
    parser.add_argument("--fsdump", required=False, help="Path to fsdump binary")
    parser.add_argument("--input-jsonl", action="store_true")
    parser.add_argument("image-nix2container")
    parser.add_argument("image-nix-snapshotter")
    args = parser.parse_args()

    if args.input_jsonl:
        with open(args.__dict__["image-nix2container"], "r") as nix2container, open(
            args.__dict__["image-nix-snapshotter"], "r"
        ) as nix_snapshotter:
            entries_nix2container = load_entries(nix2container)
            entries_nix_snapshotter = load_entries(nix_snapshotter)
    else:
        client = docker.from_env()
        if not args.fsdump:
            print("Need to set --fsdump", file=sys.stderr)
            sys.exit(1)

        fsdump_canon = Path(args.fsdump).resolve()

        kwargs = {
            "command": ["/fsdump"],
            "remove": True,
            "volumes": {str(fsdump_canon): {"bind": "/fsdump", "mode": "ro"}},
        }
        entries_nix2container = load_entries(
            StringIO(
                client.containers.run(
                    args.__dict__["image-nix2container"], **kwargs
                ).decode()
            )
        )
        entries_nix_snapshotter = load_entries(
            StringIO(
                client.containers.run(
                    args.__dict__["image-nix-snapshotter"], **kwargs
                ).decode()
            )
        )

    do_compare(entries_nix2container, entries_nix_snapshotter)


if __name__ == "__main__":
    main()
