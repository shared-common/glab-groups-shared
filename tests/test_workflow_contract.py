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

    def test_caps_mirror_matrix_with_batch_strides(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("max-parallel: 5", text)
        self.assertIn("matrix: ${{ fromJSON(needs.plan.outputs.batch-matrix) }}", text)
        self.assertIn("batch-matrix: ${{ steps.batch_matrix.outputs.matrix }}", text)
        self.assertIn("max_matrix_jobs = 256", text)
        self.assertIn('"shard_index": index', text)
        self.assertIn('"batch_stride": job_count', text)
        self.assertIn("--batch-start \"${{ matrix.batch_start }}\"", text)
        self.assertIn("--batch-stride \"${{ matrix.batch_stride }}\"", text)
        self.assertIn("--batch-limit \"${{ matrix.batch_limit }}\"", text)
        self.assertIn("needs: [plan, mirror]", text)

    def test_uses_config_specific_target_pat_secret(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("target-token-secret:", text)
        self.assertIn("GL_PAT_GROUP_KALI_SVC", text)
        self.assertIn("GL_PAT_GROUP_DEBIAN_SVC", text)
        self.assertIn("GL_PAT_GROUP_FREEDESKTOP_SVC", text)
        self.assertIn("GL_PAT_GROUP_SMALL_SVC", text)
        self.assertIn("GL_PAT_GROUP_KDE_SVC", text)
        self.assertIn("GL_PAT_GROUP_GNOME_SVC", text)
        self.assertIn("GL_PAT_GROUP_PROJ_SVC", text)
        self.assertIn("GL_TARGET_TOKEN_SECRET_NAME: ${{ inputs.target-token-secret }}", text)
        self.assertIn("GH_ORG_SHARED_APP_ID", text)
        self.assertIn("GH_ORG_SHARED_APP_INSTALL_ID", text)
        self.assertIn("GH_ORG_SHARED_APP_PEM", text)
        self.assertIn("needs-github-source-auth", text)
        self.assertNotIn("GL_GROUP_TOP_GLAB_OWNER", text)
        self.assertIn(
            'perl -I shared/lib -MGlabGroups=load_config_dir - "${CONFIG_DIR}" "${TARGET_TOKEN_SECRET}" "${GITHUB_OUTPUT}" <<\'PERL\'',
            text,
        )
        self.assertIn("$config->{projects}", text)
        self.assertNotIn('config_meta_json="$(', text)
        self.assertNotIn('needs_github_source_auth="$(', text)

    def test_report_aggregates_batch_artifacts(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("pattern: glab-results-*-${{ github.run_id }}", text)
        self.assertIn("merge-multiple: true", text)
        self.assertIn("results-artifacts/results-*.json", text)
        self.assertIn("results-artifacts/results-*.jsonl", text)
        self.assertNotIn("Fail on mirror failures", text)

    def test_step_summary_is_bounded(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("MAX_SUMMARY_CHARS = 900_000", text)
        self.assertIn("MAX_SKIPPED_ITEMS = 50", text)
        self.assertIn("MAX_FAILED_ITEMS = 50", text)
        self.assertIn('append_line(parts, "## Plan")', text)
        self.assertIn('append_line(parts, "## Report")', text)
        self.assertIn("see workflow artifacts for full JSON outputs", text)
        self.assertNotIn("plan.md\n            report.json", text)

    def test_markdown_files_are_not_uploaded_as_artifacts(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertNotIn("plan.md", text.split("Upload plan artifact", 1)[1].split("Cleanup secrets", 1)[0])
        self.assertNotIn("report.md", text.split("Upload run artifacts", 1)[1])


if __name__ == "__main__":
    unittest.main()
