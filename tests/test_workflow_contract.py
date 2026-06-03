import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "group-sync-core.yml"


class SharedWorkflowContractTests(unittest.TestCase):
    def test_artifact_actions_are_pinned_to_node24_releases(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn(
            "actions/upload-artifact@b7c566a772e6b6bfb58ed0dc250532a479d7789f",
            text,
        )
        self.assertIn(
            "actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131",
            text,
        )

    def test_uses_one_mirror_job_per_batch_with_five_way_parallelism(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("max-parallel: 5", text)
        self.assertIn("matrix: ${{ fromJSON(needs.plan.outputs.batch-matrix) }}", text)
        self.assertIn("batch-matrix: ${{ steps.batch_matrix.outputs.matrix }}", text)
        self.assertIn("--batch-start \"${{ matrix.batch_index }}\"", text)
        self.assertIn("--batch-stride 1", text)
        self.assertIn("--batch-limit 1", text)
        self.assertIn("needs: [plan, mirror]", text)

    def test_uses_config_specific_target_pat_secret(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("target-token-secret:", text)
        self.assertIn("GL_PAT_GROUP_KALI_SVC|GL_PAT_GROUP_DEBIAN_SVC", text)
        self.assertIn("GL_TARGET_TOKEN_SECRET_NAME: ${{ inputs.target-token-secret }}", text)

    def test_report_aggregates_batch_artifacts(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("pattern: glab-results-*-${{ github.run_id }}", text)
        self.assertIn("merge-multiple: true", text)
        self.assertIn("results-artifacts/results-*.json", text)
        self.assertIn("results-artifacts/results-*.jsonl", text)


if __name__ == "__main__":
    unittest.main()
