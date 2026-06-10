import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "group-sync-core.yml"


class SharedWorkflowContractTests(unittest.TestCase):
    def test_actions_are_pinned_to_current_node24_releases(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn(
            "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
            text,
        )
        self.assertIn(
            "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c",
            text,
        )
        self.assertNotIn("actions/cache@", text)

    def test_caps_mirror_matrix_with_batch_strides(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("max-parallel: 10", text)
        self.assertIn("matrix: ${{ fromJSON(needs.plan.outputs.batch-matrix) }}", text)
        self.assertIn("batch-matrix: ${{ steps.batch_matrix.outputs.matrix }}", text)
        self.assertIn("--max-batches 250", text)
        self.assertIn("max_matrix_jobs = 250", text)
        self.assertIn('"shard_index": index', text)
        self.assertIn('"batch_stride": job_count', text)
        self.assertIn("--batch-start \"${{ matrix.batch_start }}\"", text)
        self.assertIn("--batch-stride \"${{ matrix.batch_stride }}\"", text)
        self.assertIn("--batch-limit \"${{ matrix.batch_limit }}\"", text)
        self.assertIn("needs: [plan, mirror]", text)

    def test_uses_config_specific_target_pat_secret(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("mirror-secret-list: ${{ steps.config_meta.outputs.secret-list }}", text)
        self.assertIn("target-token-secret:", text)
        self.assertIn("GL_PAT_GROUP_ANDROID_SVC", text)
        self.assertIn("GL_PAT_GROUP_CHROMIUM_SVC", text)
        self.assertIn("GL_PAT_GROUP_KALI_SVC", text)
        self.assertIn("GL_PAT_GROUP_DEBIAN_SVC", text)
        self.assertIn("GL_PAT_GROUP_FREEDESKTOP_SVC", text)
        self.assertIn("GL_PAT_GROUP_SMALL_SVC", text)
        self.assertIn("GL_PAT_GROUP_HASHICORP_SVC", text)
        self.assertIn("GL_PAT_GROUP_MICROSOFT_SVC", text)
        self.assertIn("GL_PAT_GROUP_OPENAI_SVC", text)
        self.assertIn("GL_PAT_GROUP_NVIDIA_SVC", text)
        self.assertIn("GL_PAT_GROUP_KDE_SVC", text)
        self.assertIn("GL_PAT_GROUP_GNOME_SVC", text)
        self.assertIn("GL_PAT_GROUP_PROJ_SVC", text)
        self.assertIn("glab-groups-android", text)
        self.assertIn("glab-groups-chromium", text)
        self.assertIn("glab-groups-hashicorp", text)
        self.assertIn("glab-groups-microsoft", text)
        self.assertIn("glab-groups-openai", text)
        self.assertIn("glab-groups-nvidia", text)
        self.assertIn("GL_TARGET_TOKEN_SECRET_NAME: ${{ inputs.target-token-secret }}", text)
        self.assertIn("secret-list=", text)
        self.assertIn("secrets: ${{ steps.config_meta.outputs.secret-list }}", text)
        self.assertIn("secrets: ${{ needs.plan.outputs.mirror-secret-list }}", text)
        self.assertIn("GH_ORG_READ_APP_ID", text)
        self.assertIn("GH_ORG_READ_APP_INSTALL_ID", text)
        self.assertIn("GH_ORG_READ_APP_PEM", text)
        self.assertNotIn("GL_GROUP_TOP_GLAB_OWNER", text)
        self.assertNotIn("GL_BRIDGE_FORK_USER_GLAB", text)
        self.assertIn(
            'perl -I shared/lib -MGlabGroups=load_config_dir - "${CONFIG_DIR}" "${TARGET_TOKEN_SECRET}" "${GITHUB_OUTPUT}" <<\'PERL\'',
            text,
        )
        self.assertIn("$config->{projects}", text)
        self.assertIn('if [ "${SHARED_REPO}" != "shared-common/glab-groups-shared" ]; then', text)
        self.assertIn('if [ "${CONFIG_REPO}" != "shared-common/gh-actions-cfg" ]; then', text)
        self.assertIn("mcr/main|mcr/staging|mcr/release|v[0-9]*", text)
        self.assertIn('[[ ! "${ref_value}" =~ ^[0-9a-f]{40}$ ]]', text)
        self.assertNotIn('config_meta_json="$(', text)
        self.assertNotIn("NEEDS_GITHUB_SOURCE_AUTH", text)
        self.assertNotIn("python3 shared/.github/scripts/write_github_output_multiline.py", text)

    def test_report_aggregates_batch_artifacts(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("pattern: glab-results-*-${{ github.run_id }}", text)
        self.assertIn("merge-multiple: true", text)
        self.assertIn("results-artifacts/results-*.json", text)
        self.assertIn("results-artifacts/results-*.jsonl", text)
        self.assertNotIn("results-artifacts/target-groups-*.jsonl", text)
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

    def test_plan_forces_live_discovery(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("--discover-output discover.json", text)
        self.assertNotIn("force-refresh-discovery:", text)
        self.assertNotIn("Restore source inventory cache", text)
        self.assertNotIn("inventory-cache", text)
        self.assertNotIn("--inventory-output", text)
        self.assertNotIn("--inventory-max-age-seconds", text)
        self.assertNotIn("--inventory-input", text)

    def test_prepare_job_runs_before_mirror(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("prepare:\n    needs: plan", text)
        self.assertIn("Prepare target namespaces and projects", text)
        self.assertIn("prepare-target", text)
        self.assertIn("needs: [plan, prepare]", text)

    def test_metadata_repo_is_not_used(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertNotIn("shared-common/glab-groups-metadata", text)
        self.assertNotIn("update_metadata_repo.py", text)
        self.assertNotIn("target-groups-${{ matrix.shard_index }}.jsonl", text)


if __name__ == "__main__":
    unittest.main()
