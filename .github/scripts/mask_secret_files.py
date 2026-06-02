from __future__ import annotations

import os
import re
from pathlib import Path


NAME_RE = re.compile(r"^[A-Z0-9_]+$")


def parse_csv(value: str) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []
    for item in value.split(","):
        name = item.strip()
        if not name or name in seen:
            continue
        seen.add(name)
        ordered.append(name)
    return ordered


def escape_workflow_command(value: str) -> str:
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def iter_mask_values(value: str) -> list[str]:
    values = [value]
    normalized = value.replace("\r\n", "\n").replace("\r", "\n")
    if "\n" in normalized:
        values.extend(line for line in normalized.split("\n") if line)
    return values


def main() -> int:
    secret_names = parse_csv(os.environ.get("SECRET_NAMES", ""))
    if not secret_names:
        raise SystemExit("SECRET_NAMES is empty")

    seen_values: set[str] = set()
    for name in secret_names:
        if not NAME_RE.match(name):
            raise SystemExit(f"Invalid secret name: {name}")

        path_value = os.environ.get(f"{name}_FILE", "").strip()
        if not path_value:
            raise SystemExit(f"Missing required secret file env var: {name}_FILE")
        path = Path(path_value)
        value = path.read_text(encoding="utf-8")
        if not value:
            raise SystemExit(f"Empty secret file for {name}")
        for item in iter_mask_values(value):
            if item in seen_values:
                continue
            seen_values.add(item)
            print(f"::add-mask::{escape_workflow_command(item)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
