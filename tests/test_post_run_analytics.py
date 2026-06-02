import csv
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / ".github" / "scripts" / "post_run_analytics.py"


class PostRunAnalyticsTests(unittest.TestCase):
    def test_writes_csv_and_summary_json(self) -> None:
        report = {
            "result_counts": {
                "failed": 1,
                "mirrored": 2,
                "skipped": 1,
            }
        }
        rows = [
            {
                "target_full_path": "glab-forks/kalilinux/demo",
                "planned_action": "create_project",
                "status": "mirrored",
                "selected_refs": {"branches": ["main"], "tags": []},
                "size": {"total_bytes": 42, "oversized_blobs": []},
            },
            {
                "target_full_path": "glab-forks/debian/demo",
                "planned_action": "mirror_only",
                "status": "skipped",
                "reason": "Repository above permitted size limit.",
                "selected_refs": {"branches": ["main", "pristine-tar"], "tags": []},
                "size": {"total_bytes": 0, "oversized_blobs": []},
            },
        ]

        with tempfile.TemporaryDirectory() as tmp_dir:
            base = Path(tmp_dir)
            report_path = base / "report.json"
            jsonl_path = base / "results.jsonl"
            csv_path = base / "results.csv"
            analytics_path = base / "analytics.json"
            report_path.write_text(json.dumps(report), encoding="utf-8")
            jsonl_path.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")

            subprocess.run(
                [
                    "python3",
                    str(SCRIPT),
                    "--report",
                    str(report_path),
                    "--jsonl",
                    str(jsonl_path),
                    "--csv",
                    str(csv_path),
                    "--json",
                    str(analytics_path),
                ],
                check=True,
            )

            with csv_path.open(newline="", encoding="utf-8") as handle:
                csv_rows = list(csv.DictReader(handle))
            analytics = json.loads(analytics_path.read_text(encoding="utf-8"))

        self.assertEqual(len(csv_rows), 2)
        self.assertEqual(csv_rows[1]["reason"], "Repository above permitted size limit.")
        self.assertEqual(analytics["generated_rows"], 2)
        self.assertEqual(analytics["status_breakdown"]["mirrored"], 1)
        self.assertEqual(analytics["status_breakdown"]["skipped"], 1)


if __name__ == "__main__":
    unittest.main()
