#!/usr/bin/env python3
"""Render deployment-specific tracked templates from exported .env values."""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
OUTPUTS = {
    ROOT / "crowdsec/whitelist.yaml.template": ROOT / "crowdsec/whitelist.yaml",
    ROOT / "prometheus/rules/alerts.yml.template": ROOT / "prometheus/rules/alerts.yml",
    ROOT / "router/syslog-ng-remote.conf.template": ROOT / "router/syslog-ng-remote.conf",
}
VARIABLE = re.compile(r"\$\{([A-Z][A-Z0-9_]*)\}")


def render(source: Path, destination: Path) -> None:
    text = source.read_text()
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
