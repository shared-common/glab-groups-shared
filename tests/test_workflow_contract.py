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
        self.assertIn("GH_SSH_GROUPS_METADATA_KEY", text)
        self.assertIn("GH_ORG_READ_APP_ID", text)
        self.assertIn("GH_ORG_READ_APP_INSTALL_ID", text)
        self.assertIn("GH_ORG_READ_APP_PEM", text)
        self.assertIn("needs-github-source-auth", text)
        self.assertNotIn("GL_GROUP_TOP_GLAB_OWNER", text)
        self.assertNotIn("GL_BRIDGE_FORK_USER_GLAB", text)
        self.assertIn(
            'perl -I shared/lib -MGlabGroups=load_config_dir - "${CONFIG_DIR}" "${TARGET_TOKEN_SECRET}" "${GITHUB_OUTPUT}" <<\'PERL\'',
            text,
        )
        self.assertIn("$config->{projects}", text)
        self.assertIn("inventory-cache-max-age-seconds", text)
        self.assertNotIn('config_meta_json="$(', text)
        self.assertNotIn('needs_github_source_auth="$(', text)
        self.assertEqual(
            text.count("python3 shared/.github/scripts/write_github_output_multiline.py"),
            2,
        )
        self.assertNotIn("cat .secrets/GH_SSH_GROUPS_METADATA_KEY", text)

    def test_report_aggregates_batch_artifacts(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("pattern: glab-results-*-${{ github.run_id }}", text)
        self.assertIn("merge-multiple: true", text)
        self.assertIn("results-artifacts/results-*.json", text)
        self.assertIn("results-artifacts/results-*.jsonl", text)
        self.assertIn("results-artifacts/target-groups-*.jsonl", text)
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

    def test_plan_uses_inventory_cache(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("force-refresh-discovery:", text)
        self.assertIn("Restore source inventory cache", text)
        self.assertIn("if: ${{ !inputs.force-refresh-discovery }}", text)
        self.assertIn("actions/cache@v5", text)
        self.assertIn("inventory-cache", text)
        self.assertIn("--discover-output discover.json", text)
        self.assertIn("--inventory-output \"inventory-cache/discover.json\"", text)
        self.assertIn('--inventory-max-age-seconds "${{ steps.config_meta.outputs.inventory-cache-max-age-seconds }}"', text)
        self.assertIn('--target-group-cache-input "metadata/cache/${{ inputs.config-path }}/target-groups.jsonl"', text)
        self.assertIn('FORCE_REFRESH_DISCOVERY: ${{ inputs.force-refresh-discovery }}', text)
        self.assertIn('if [ "${FORCE_REFRESH_DISCOVERY}" != "true" ]; then', text)
        self.assertIn('inventory_args+=(--inventory-input "inventory-cache/discover.json")', text)
        self.assertIn("rm -rf inventory-cache", text)

    def test_metadata_repo_is_read_and_written(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("repository: shared-common/glab-groups-metadata", text)
        self.assertIn("path: metadata", text)
        self.assertIn("python3 shared/.github/scripts/update_metadata_repo.py", text)
        self.assertIn('git push origin HEAD:main', text)


if __name__ == "__main__":
    unittest.main()
