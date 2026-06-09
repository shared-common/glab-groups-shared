from __future__ import annotations

import argparse
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--metadata-dir", required=True)
    parser.add_argument("--config-path", required=True)
    parser.add_argument("--plan", required=True)
    parser.add_argument("--discovery", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--analytics", required=True)
    parser.add_argument("--target-groups-jsonl", action="append", default=[])
    parser.add_argument("--event-name", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--run-attempt", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--workflow-ref", required=True)
    return parser.parse_args()


def timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_json(path: str) -> Any:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def load_jsonl(path: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    raw_path = Path(path)
    if not raw_path.is_file():
        return rows
    for line in raw_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        rows.append(json.loads(line))
    return rows


def append_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n")


def validate_config_path(config_path: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", config_path):
        raise SystemExit(f"invalid config-path: {config_path}")
    return config_path


def run_identity(args: argparse.Namespace) -> dict[str, str]:
    return {
        "config_path": args.config_path,
        "event_name": args.event_name,
        "repository": args.repository,
        "run_attempt": str(args.run_attempt),
        "run_id": str(args.run_id),
        "sha": args.sha,
        "workflow_ref": args.workflow_ref,
    }


def append_run_record(path: Path, record: dict[str, Any]) -> None:
    existing = load_jsonl(str(path))
    run_id = record["run"]["run_id"]
    run_attempt = record["run"]["run_attempt"]
    for row in existing:
        row_run = row.get("run") or {}
        if row_run.get("run_id") == run_id and row_run.get("run_attempt") == run_attempt:
            return
    append_jsonl(path, [record])


def extract_source_gitlab_group_records(
    discovery: dict[str, Any],
    config_path: str,
    run: dict[str, str],
) -> list[dict[str, Any]]:
    records: dict[tuple[str, str, int], dict[str, Any]] = {}
    for bucket in discovery.get("inventory") or []:
        if not isinstance(bucket, dict):
            continue
        base_url = bucket.get("base_url")
        if not isinstance(base_url, str) or not base_url.startswith("https://"):
            continue

        bucket_group_path = bucket.get("group_path")
        bucket_group_id = bucket.get("group_id")
        if isinstance(bucket_group_path, str) and isinstance(bucket_group_id, int):
            key = (base_url, bucket_group_path, bucket_group_id)
            records[key] = {
                "config_path": config_path,
                "recorded_at": timestamp(),
                "run": run,
                "source_base_url": base_url,
                "source_group_id": bucket_group_id,
                "source_group_path": bucket_group_path,
            }

        for project in bucket.get("projects") or []:
            if not isinstance(project, dict):
                continue
            namespace = project.get("namespace")
            if not isinstance(namespace, dict):
                continue
            namespace_id = namespace.get("id")
            namespace_path = namespace.get("full_path") or namespace.get("path")
            if not isinstance(namespace_id, int) or not isinstance(namespace_path, str):
                continue
            key = (base_url, namespace_path, namespace_id)
            records[key] = {
                "config_path": config_path,
                "recorded_at": timestamp(),
                "run": run,
                "source_base_url": base_url,
                "source_group_id": namespace_id,
                "source_group_path": namespace_path,
            }
    return [records[key] for key in sorted(records)]


def load_target_group_records(
    paths: list[str],
    config_path: str,
    run: dict[str, str],
) -> list[dict[str, Any]]:
    records: dict[tuple[str, int], dict[str, Any]] = {}
    for path in paths:
        for row in load_jsonl(path):
            target_group_path = row.get("target_group_path")
            target_group_id = row.get("target_group_id")
            if not isinstance(target_group_path, str) or not isinstance(target_group_id, int):
                continue
            key = (target_group_path, target_group_id)
            records[key] = {
                "config_path": config_path,
                "recorded_at": timestamp(),
                "run": run,
                "target_group_id": target_group_id,
                "target_group_path": target_group_path,
            }
    return [records[key] for key in sorted(records)]


def append_new_group_records(path: Path, rows: list[dict[str, Any]], path_key: str, id_key: str) -> None:
    existing = {
        (
            row.get(path_key),
            row.get(id_key),
        )
        for row in load_jsonl(str(path))
        if isinstance(row, dict)
    }
    new_rows = [
        row
        for row in rows
        if (row.get(path_key), row.get(id_key)) not in existing
    ]
    if new_rows:
        append_jsonl(path, new_rows)


def discovery_summary(discovery: dict[str, Any]) -> dict[str, Any]:
    inventory = [item for item in discovery.get("inventory") or [] if isinstance(item, dict)]
    project_count = 0
    for bucket in inventory:
        project_count += len([project for project in bucket.get("projects") or [] if isinstance(project, dict)])
    return {
        "discovered_at": discovery.get("discovered_at"),
        "inventory_buckets": len(inventory),
        "inventory_projects": project_count,
    }


def plan_summary(plan: dict[str, Any]) -> dict[str, Any]:
    return {
        "batch_size": plan.get("batch_size"),
        "counts": plan.get("counts") or {},
        "generated_at": plan.get("generated_at"),
        "total_batches": plan.get("total_batches"),
        "total_groups": plan.get("total_groups"),
        "total_targets": plan.get("total_targets"),
    }


def report_summary(report: dict[str, Any]) -> dict[str, Any]:
    return {
        "generated_at": report.get("generated_at"),
        "plan_counts": report.get("plan_counts") or {},
        "result_counts": report.get("result_counts") or {},
    }


def analytics_summary(analytics: dict[str, Any]) -> dict[str, Any]:
    return analytics


def make_run_record(kind: str, run: dict[str, str], summary: dict[str, Any]) -> dict[str, Any]:
    return {
        "kind": kind,
        "recorded_at": timestamp(),
        "run": run,
        "summary": summary,
    }


def main() -> int:
    args = parse_args()
    config_path = validate_config_path(args.config_path)
    metadata_dir = Path(args.metadata_dir)
    run = run_identity(args)
    run["config_path"] = config_path

    plan = load_json(args.plan)
    discovery = load_json(args.discovery)
    report = load_json(args.report)
    analytics = load_json(args.analytics)

    cache_dir = metadata_dir / "cache" / config_path
    runs_dir = metadata_dir / "runs" / config_path

    append_new_group_records(
        cache_dir / "source-groups.jsonl",
        extract_source_gitlab_group_records(discovery, config_path, run),
        "source_group_path",
        "source_group_id",
    )
    append_new_group_records(
        cache_dir / "target-groups.jsonl",
        load_target_group_records(args.target_groups_jsonl, config_path, run),
        "target_group_path",
        "target_group_id",
    )

    append_run_record(
        runs_dir / "discovery.jsonl",
        make_run_record("glab-groups/discovery-summary", run, discovery_summary(discovery)),
    )
    append_run_record(
        runs_dir / "plan.jsonl",
        make_run_record("glab-groups/plan-summary", run, plan_summary(plan)),
    )
    append_run_record(
        runs_dir / "report.jsonl",
        make_run_record("glab-groups/report-summary", run, report_summary(report)),
    )
    append_run_record(
        runs_dir / "analytics.jsonl",
        make_run_record("glab-groups/analytics-summary", run, analytics_summary(analytics)),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
