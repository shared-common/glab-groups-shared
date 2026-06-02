import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "group-sync-core.yml"


class SharedWorkflowContractTests(unittest.TestCase):
    def test_uses_five_parallel_mirror_lanes(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("max-parallel: 5", text)
        self.assertIn("lane: [0, 1, 2, 3, 4]", text)
        self.assertIn("--batch-stride 5", text)
        self.assertIn("needs: [plan, mirror]", text)

    def test_report_aggregates_lane_artifacts(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("pattern: glab-groups-results-${{ inputs.config-path }}-*-${{ github.run_id }}", text)
        self.assertIn("merge-multiple: true", text)
        self.assertIn("results-artifacts/results-*.json", text)
        self.assertIn("results-artifacts/results-*.jsonl", text)


if __name__ == "__main__":
    unittest.main()
