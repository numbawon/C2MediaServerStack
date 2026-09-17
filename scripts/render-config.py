#!/usr/bin/env python3
"""Render deployment-specific tracked templates from exported .env values."""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
OUTPUTS = {
    ROOT / "docker-compose.home.yml.template": ROOT / "docker-compose.home.yml",
    ROOT / "crowdsec/whitelist.yaml.template": ROOT / "crowdsec/whitelist.yaml",
    ROOT / "prometheus/rules/alerts.yml.template": ROOT / "prometheus/rules/alerts.yml",
    ROOT / "router/syslog-ng-remote.conf.template": ROOT / "router/syslog-ng-remote.conf",
}
VARIABLE = re.compile(r"\$\{([A-Z][A-Z0-9_]*)\}")
DEVICE = re.compile(r"^/dev/[A-Za-z0-9._/-]+$")


def render(source: Path, destination: Path) -> None:
    text = source.read_text()
    if source.name == "docker-compose.home.yml.template":
        devices = list(
            dict.fromkeys(
                device.strip()
                for device in os.environ.get("SCRUTINY_DEVICES", "").split(",")
                if device.strip()
            )
        )
        invalid = [
            device
            for device in devices
            if not DEVICE.fullmatch(device) or ".." in Path(device).parts
        ]
        if not devices or invalid:
            detail = ", ".join(invalid) if invalid else "empty device list"
            raise RuntimeError(f"invalid SCRUTINY_DEVICES: {detail}")
        # Omnibus starts its embedded stores as root against bind mounts
        # commonly owned by the host user. DAC_OVERRIDE is narrower than
        # privileged mode and lets only this container traverse those mounts.
        capabilities = ["DAC_OVERRIDE", "SYS_RAWIO"]
        if any(Path(device).name.startswith("nvme") for device in devices):
            capabilities.append("SYS_ADMIN")
        text = text.replace(
            "@SCRUTINY_CAPABILITIES@",
            "\n".join(f"      - {capability}" for capability in capabilities),
        )
        text = text.replace(
            "@SCRUTINY_DEVICE_MAPPINGS@",
            "\n".join(f"      - {device}:{device}" for device in devices),
        )

    missing = sorted({name for name in VARIABLE.findall(text) if not os.environ.get(name)})
    if missing:
        names = ", ".join(missing)
        raise RuntimeError(f"{source.relative_to(ROOT)}: missing environment values: {names}")

    rendered = VARIABLE.sub(lambda match: os.environ[match.group(1)], text)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    temporary.write_text(rendered)
    temporary.replace(destination)
    print(f"rendered {destination.relative_to(ROOT)}")


def main() -> int:
    try:
        for source, destination in OUTPUTS.items():
            render(source, destination)
    except (OSError, RuntimeError) as error:
        print(f"render-config: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
