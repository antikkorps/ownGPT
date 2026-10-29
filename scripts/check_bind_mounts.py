#!/usr/bin/env python3
"""Refuse single-file bind mounts in the Compose config (JSON on stdin).

Docker Desktop on WSL restarts containers before the distro's filesystem is
ready; a file bind mount then fails with "not a directory" and the container
is never retried. Directory mounts survive, so every bind source must be one.
Usage: docker compose config --format json | python3 scripts/check_bind_mounts.py
"""
import json
import os
import sys


def file_mounts(config):
    """Yield (service, source) for each bind mount whose source is a regular file."""
    for name, service in config.get("services", {}).items():
        for volume in service.get("volumes", []):
            # A missing source is fine: Docker creates it as a directory.
            if volume.get("type") == "bind" and os.path.isfile(volume["source"]):
                yield name, volume["source"]


def main():
    bad = list(file_mounts(json.load(sys.stdin)))
    for name, source in bad:
        print(f"ERREUR : {name} monte un fichier ({source}) ; monter son dossier", file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
