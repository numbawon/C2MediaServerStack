#!/usr/bin/env python3
"""Validate required deployment variables after .env is exported."""

from __future__ import annotations

import os
import sys


EXPECTED_VERSION = "2"
REQUIRED = (
    "COMMON_CONFIG_VERSION",
    "COMMON_PUID",
    "COMMON_PGID",
    "COMMON_MEDIA",
    "COMMON_STORAGE",
    "COMMON_UPLOADS",
    "COMMON_LAN_SUBNET",
    "COMMON_LAN_IP",
    "COMMON_LAN_ROUTER",
    "COMMON_EDGE_SUBNET",
    "COMMON_INTERNAL_SUBNET",
    "COMMON_DOCKER_GWBRIDGE_SUBNET",
    "COMMON_DOCKER_GWBRIDGE_GATEWAY",
    "COMMON_PIHOLE_HOSTNAME",
    "COMMON_TDARR_NODE_NAME",
    "COMMON_DEPLOYMENT_COMPONENTS",
    "COMMON_NVIDIA_DEVICE_COUNT",
    "COMMON_NVIDIA_VISIBLE_DEVICES",
    "OLLAMA_MAX_LOADED_MODELS",
    "OLLAMA_NUM_PARALLEL",
    "OLLAMA_KEEP_ALIVE",
    "OLLAMA_KV_CACHE_TYPE",
    "HERMES_CPUS",
    "HERMES_MEMORY",
    "PROM_SYSTEM_WARN_FREE_BYTES",
    "PROM_SYSTEM_CRIT_FREE_BYTES",
    "PROM_MEDIA_WARN_FREE_BYTES",
    "PROM_MEDIA_CRIT_FREE_BYTES",
)


def main() -> int:
    missing = [name for name in REQUIRED if not os.environ.get(name)]
    if missing:
        print(
            "Environment is missing required values: " + ", ".join(missing),
            file=sys.stderr,
        )
        print("Merge new keys from .env.example into .env.", file=sys.stderr)
        return 1

    version = os.environ["COMMON_CONFIG_VERSION"]
    if version != EXPECTED_VERSION:
        print(
            f".env version {version!r} is unsupported; expected "
            f"{EXPECTED_VERSION}. Merge changes from .env.example.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
