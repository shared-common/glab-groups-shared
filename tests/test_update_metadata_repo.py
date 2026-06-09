import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / ".github" / "scripts" / "update_metadata_repo.py"


def load_jsonl(path: Path) -> list[dict]:
    rows: list[dict] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        rows.append(json.loads(line))
    return rows


class UpdateMetadataRepoTests(unittest.TestCase):
    def test_appends_gitlab_group_caches_and_run_summaries(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            base = Path(tmp_dir)
            metadata_dir = base / "metadata"
            metadata_dir.mkdir()

            discovery_path = base / "discover.json"
            discovery_path.write_text(
                json.dumps(
                    {
                        "discovered_at": "2026-06-09T12:00:00Z",
                        "inventory": [
                            {
                                "base_url": "https://gitlab.freedesktop.org",
                                "group_id": 101,
                                "group_path": "wlroots",
                                "projects": [
                                    {
                                        "namespace": {
                                            "full_path": "wlroots/subgroup",
                                            "id": 202,
                                        }
                                    }
                                ],
                            },
                            {
                                "base_url": "https://github.com",
                                "group_path": "openai",
                                "projects": [{}],
                            },
                        ],
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            plan_path = base / "plan.json"
            plan_path.write_text(
                json.dumps(
                    {
                        "batch_size": 25,
                        "counts": {"sync": 3, "skip": 0, "fail": 0},
                        "generated_at": "2026-06-09T12:01:00Z",
                        "total_batches": 2,
                        "total_groups": 2,
                        "total_targets": 3,
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            report_path = base / "report.json"
            report_path.write_text(
                json.dumps(
                    {
                        "generated_at": "2026-06-09T12:02:00Z",
                        "plan_counts": {"sync": 3, "skip": 0, "fail": 0},
                        "result_counts": {"mirrored": 3, "skipped": 0, "failed": 0},
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            analytics_path = base / "analytics.json"
            analytics_path.write_text(
                json.dumps({"generated_rows": 3, "status_breakdown": {"mirrored": 3}}) + "\n",
                encoding="utf-8",
            )

            target_groups_path = base / "target-groups-0.jsonl"
            target_groups_path.write_text(
                json.dumps({"target_group_id": 303, "target_group_path": "glab-forks/wlroots"}) + "\n",
                encoding="utf-8",
            )

            cmd = [
                "python3",
                str(SCRIPT),
                "--metadata-dir",
                str(metadata_dir),
                "--config-path",
                "glab-groups-freedesktop",
                "--plan",
                str(plan_path),
                "--discovery",
                str(discovery_path),
                "--report",
                str(report_path),
                "--analytics",
                str(analytics_path),
                "--target-groups-jsonl",
                str(target_groups_path),
                "--event-name",
                "schedule",
                "--repository",
                "shared-common/glab-groups-freedesktop",
                "--run-attempt",
                "1",
                "--run-id",
                "999",
                "--sha",
                "deadbeef",
                "--workflow-ref",
                "shared-common/glab-groups-freedesktop/.github/workflows/group-sync.yml@refs/heads/mcr/main",
            ]
            subprocess.run(cmd, check=True)
            subprocess.run(cmd, check=True)

            source_cache = load_jsonl(metadata_dir / "cache" / "glab-groups-freedesktop" / "source-groups.jsonl")
            target_cache = load_jsonl(metadata_dir / "cache" / "glab-groups-freedesktop" / "target-groups.jsonl")
            discovery_runs = load_jsonl(metadata_dir / "runs" / "glab-groups-freedesktop" / "discovery.jsonl")
            plan_runs = load_jsonl(metadata_dir / "runs" / "glab-groups-freedesktop" / "plan.jsonl")
            report_runs = load_jsonl(metadata_dir / "runs" / "glab-groups-freedesktop" / "report.jsonl")
            analytics_runs = load_jsonl(metadata_dir / "runs" / "glab-groups-freedesktop" / "analytics.jsonl")

        self.assertEqual(len(source_cache), 2)
        self.assertEqual({row["source_group_id"] for row in source_cache}, {101, 202})
        self.assertEqual(len(target_cache), 1)
        self.assertEqual(target_cache[0]["target_group_id"], 303)
        self.assertEqual(len(discovery_runs), 1)
        self.assertEqual(discovery_runs[0]["summary"]["inventory_projects"], 2)
        self.assertEqual(len(plan_runs), 1)
        self.assertEqual(plan_runs[0]["summary"]["total_groups"], 2)
        self.assertEqual(len(report_runs), 1)
        self.assertEqual(report_runs[0]["summary"]["result_counts"]["mirrored"], 3)
        self.assertEqual(len(analytics_runs), 1)
        self.assertEqual(analytics_runs[0]["summary"]["generated_rows"], 3)


if __name__ == "__main__":
    unittest.main()
