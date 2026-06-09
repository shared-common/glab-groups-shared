from __future__ import annotations

import argparse
import hashlib
import re
from pathlib import Path


OUTPUT_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*$")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Append a multiline GitHub Actions step output from a file.",
    )
    parser.add_argument("--output-file", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--value-file", required=True)
    return parser


def normalize_newlines(value: str) -> str:
    return value.replace("\r\n", "\n").replace("\r", "\n")


def choose_delimiter(value: str) -> str:
    normalized_lines = set(normalize_newlines(value).split("\n"))
    digest = hashlib.sha256(value.encode("utf-8")).hexdigest()
    for counter in range(100):
        delimiter = f"__GH_OUTPUT_{digest}_{counter}__"
        if delimiter not in normalized_lines:
            return delimiter
    raise SystemExit("Unable to choose a safe multiline output delimiter")


def append_multiline_output(output_file: Path, name: str, value: str) -> None:
    delimiter = choose_delimiter(value)
    with output_file.open("a", encoding="utf-8", newline="\n") as handle:
        handle.write(f"{name}<<{delimiter}\n")
        handle.write(value)
        if not value.endswith("\n"):
            handle.write("\n")
        handle.write(f"{delimiter}\n")


def main() -> int:
    args = build_parser().parse_args()
    if not OUTPUT_NAME_RE.match(args.name):
        raise SystemExit(f"Invalid GitHub output name: {args.name}")

    output_file = Path(args.output_file)
    value_file = Path(args.value_file)
    value = value_file.read_text(encoding="utf-8")
    if not value:
        raise SystemExit(f"Empty value file: {value_file}")

    append_multiline_output(output_file, args.name, value)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
