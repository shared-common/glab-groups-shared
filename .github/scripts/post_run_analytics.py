from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", required=True)
    parser.add_argument("--jsonl", action="append", required=True)
    parser.add_argument("--csv", required=True)
    parser.add_argument("--json", required=True)
    parser.add_argument("--parquet")
    return parser.parse_args()


def load_json(path: str) -> Any:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def load_jsonl(path: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        rows.append(json.loads(line))
    return rows


def load_jsonl_files(paths: list[str]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for path in paths:
        rows.extend(load_jsonl(path))
    return rows


def flatten_row(row: dict[str, Any]) -> dict[str, Any]:
    selected = row.get("selected_refs") or {}
    size = row.get("size") or {}
    return {
        "target_full_path": row.get("target_full_path", ""),
        "planned_action": row.get("planned_action", ""),
        "status": row.get("status", ""),
        "reason": row.get("reason", ""),
        "error": row.get("error", ""),
        "needs_lfs": bool(row.get("needs_lfs")),
        "lfs_rewrite_attempted": bool(row.get("lfs_rewrite_attempted")),
        "branch_count": len(selected.get("branches") or []),
        "tag_count": len(selected.get("tags") or []),
        "total_bytes": int(size.get("total_bytes") or 0),
        "oversized_blob_count": len(size.get("oversized_blobs") or []),
    }


def write_csv(path: str, rows: list[dict[str, Any]]) -> None:
    fieldnames = [
        "target_full_path",
        "planned_action",
        "status",
        "reason",
        "error",
        "needs_lfs",
        "lfs_rewrite_attempted",
        "branch_count",
        "tag_count",
        "total_bytes",
        "oversized_blob_count",
    ]
    with Path(path).open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def write_parquet(path: str, rows: list[dict[str, Any]]) -> str:
    try:
        import pyarrow as pa
        import pyarrow.parquet as pq
    except ImportError:
        return "pyarrow not installed"

    table = pa.Table.from_pylist(rows)
    pq.write_table(table, path)
    return ""


def main() -> int:
    args = parse_args()
    report = load_json(args.report)
    raw_rows = load_jsonl_files(args.jsonl)
    rows = [flatten_row(row) for row in raw_rows]

    write_csv(args.csv, rows)

    analytics = {
        "generated_rows": len(rows),
        "report_counts": report.get("result_counts", {}),
        "status_breakdown": {},
        "parquet": {
            "requested": bool(args.parquet),
            "written": False,
            "message": "",
        },
    }
    for row in rows:
        analytics["status_breakdown"][row["status"]] = analytics["status_breakdown"].get(row["status"], 0) + 1

    if args.parquet:
        message = write_parquet(args.parquet, rows)
        analytics["parquet"]["written"] = message == ""
        analytics["parquet"]["message"] = message

    Path(args.json).write_text(json.dumps(analytics, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
