import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "group-sync-core.yml"
VALIDATE_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "validate-shared.yml"


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

    def test_uses_discovery_and_mirror_matrices(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("discover-matrix: ${{ steps.discovery_matrix.outputs.matrix }}", text)
        self.assertIn("discover-secret-list: ${{ steps.config_meta.outputs.discover-secret-list }}", text)
        self.assertIn("discover-units=", text)
        self.assertIn('matrix: ${{ fromJSON(needs.bootstrap.outputs.discover-matrix) }}', text)
        self.assertIn('"unit_start": index', text)
        self.assertIn('"unit_stride": job_count', text)
        self.assertIn("--unit-start \"${{ matrix.unit_start }}\"", text)
        self.assertIn("--unit-stride \"${{ matrix.unit_stride }}\"", text)
        self.assertIn("--unit-limit \"${{ matrix.unit_limit }}\"", text)
        self.assertIn('max-parallel: ${{ fromJSON(needs.plan.outputs.max-parallel) }}', text)
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
        self.assertIn("mirror-secret-list: ${{ steps.config_meta.outputs.mirror-secret-list }}", text)
        self.assertIn("discover-secret-list: ${{ steps.config_meta.outputs.discover-secret-list }}", text)
        self.assertIn("batch-size: ${{ steps.config_meta.outputs.batch-size }}", text)
        self.assertIn("max-parallel: ${{ steps.config_meta.outputs.max-parallel }}", text)
        self.assertIn("target-token-secret:", text)
        self.assertIn("projects-only:", text)
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
        self.assertIn("mirror-secret-list=", text)
        self.assertIn("discover-secret-list=", text)
        self.assertIn("secrets: ${{ needs.bootstrap.outputs.discover-secret-list }}", text)
        self.assertIn("secrets: ${{ needs.plan.outputs.mirror-secret-list }}", text)
        self.assertIn("GH_ORG_READ_APP_ID", text)
        self.assertIn("GH_ORG_READ_APP_INSTALL_ID", text)
        self.assertIn("GH_ORG_READ_APP_PEM", text)
        self.assertIn("GL_USER_GLAB_FORKS_NAME", text)
        self.assertIn("GL_USER_GLAB_FORKS_TOKEN", text)
        self.assertIn("GIT_BRANCH_GLAB_FORKS", text)
        self.assertIn('PROJECTS_ONLY: ${{ inputs.projects-only }}', text)
        self.assertIn('"${PROJECTS_ONLY}"', text)
        self.assertIn("plan_args=()", text)
        self.assertIn("plan_args+=(--projects-only)", text)
        self.assertNotIn("GL_GROUP_TOP_GLAB_OWNER", text)
        self.assertNotIn("GL_BRIDGE_FORK_USER_GLAB", text)
        self.assertIn(
            'perl -I shared/lib -MGlabGroups=load_config_dir - "${CONFIG_DIR}" "${TARGET_TOKEN_SECRET}" "${PROJECTS_ONLY}" "${GITHUB_OUTPUT}" <<\'PERL\'',
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
        self.assertIn("Publish batch summary", text)
        self.assertIn("MAX_BATCH_ITEMS = 20", text)
        self.assertIn('append_line(parts, f"## Batch Shard {shard_index}")', text)
        self.assertIn('append_line(parts, "### Skipped")', text)
        self.assertIn('append_line(parts, "### Failed")', text)
        self.assertIn("MAX_SUMMARY_CHARS = 900_000", text)
        self.assertIn("MAX_MISSING_SOURCE_GROUPS = 50", text)
        self.assertIn("MAX_SKIPPED_ITEMS = 50", text)
        self.assertIn("MAX_FAILED_ITEMS = 50", text)
        self.assertIn('append_line(parts, "## Plan")', text)
        self.assertIn('append_line(parts, "### Missing Source Groups")', text)
        self.assertIn('append_line(parts, f"- missing source groups: {len(missing_source_groups)}")', text)
        self.assertIn('append_line(parts, "## Report")', text)
        self.assertIn("see workflow artifacts for full JSON outputs", text)
        self.assertNotIn("plan.md\n            report.json", text)

    def test_markdown_files_are_not_uploaded_as_artifacts(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertNotIn("plan.md", text.split("Upload plan artifact", 1)[1].split("Cleanup secrets", 1)[0])
        self.assertNotIn("report.md", text.split("Upload run artifacts", 1)[1])

    def test_plan_uses_discovery_shards_without_cache(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("discover-artifacts/discover-*.json", text)
        self.assertIn("glab-discover-${{ matrix.shard_index }}-${{ github.run_id }}", text)
        self.assertIn("merge-multiple: true", text)
        self.assertIn("discover \\", text)
        self.assertIn("--discover-input", text)
        self.assertIn("--discover-output discover.json", text)
        self.assertNotIn("force-refresh-discovery:", text)
        self.assertNotIn("Restore source inventory cache", text)
        self.assertNotIn("inventory-cache", text)
        self.assertNotIn("--inventory-output", text)
        self.assertNotIn("--inventory-max-age-seconds", text)
        self.assertNotIn("--inventory-input", text)

    def test_mirror_runs_directly_from_plan_without_prepare_job(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn('max-parallel: ${{ fromJSON(needs.plan.outputs.max-parallel) }}', text)
        self.assertIn('matrix: ${{ fromJSON(needs.plan.outputs.batch-matrix) }}', text)
        self.assertIn('--batch-start "${{ matrix.batch_start }}"', text)
        self.assertIn('--batch-stride "${{ matrix.batch_stride }}"', text)
        self.assertIn('--batch-limit "${{ matrix.batch_limit }}"', text)
        self.assertIn("discover:\n    needs: bootstrap", text)
        self.assertIn("plan:\n    needs: [bootstrap, discover]", text)
        self.assertIn("mirror:\n    needs: plan", text)
        self.assertNotIn("prepare:\n    needs: plan", text)
        self.assertNotIn("Prepare target namespaces and projects", text)
        self.assertNotIn("Upload prepared target artifacts", text)
        self.assertNotIn("prepare-target", text)
        self.assertNotIn('prepared-${{ matrix.shard_index }}.json', text)
        self.assertNotIn("Download prepared target artifact", text)
        self.assertNotIn('--prepared "prepared-${{ matrix.shard_index }}.json"', text)

    def test_metadata_repo_is_not_used(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertNotIn("shared-common/glab-groups-metadata", text)
        self.assertNotIn("update_metadata_repo.py", text)
        self.assertNotIn("target-groups-${{ matrix.shard_index }}.jsonl", text)

    def test_validation_workflow_covers_runtime_and_central_config_repo(self) -> None:
        text = VALIDATE_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("name: validate-shared", text)
        self.assertIn('group: validate-shared-${{ github.ref }}', text)
        self.assertIn("shared-runtime:", text)
        self.assertIn("config-compatibility:", text)
        self.assertIn(
            "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd",
            text,
        )
        self.assertIn("repository: shared-common/gh-actions-cfg", text)
        self.assertIn("ref: mcr/main", text)
        self.assertIn("LC_ALL=C TZ=UTC perl -c .github/scripts/glab_groups.pl", text)
        self.assertIn("LC_ALL=C TZ=UTC prove -Ilib tests/test_glab_groups.t", text)
        self.assertIn(
            "LC_ALL=C TZ=UTC python3 -m unittest discover -s tests -p 'test_*.py'",
            text,
        )
        self.assertIn("perl -I shared/lib -MGlabGroups=load_config_dir -", text)
        self.assertIn("find gh-actions-cfg -mindepth 1 -maxdepth 1 -type d -name 'glab-groups-*' | sort", text)


if __name__ == "__main__":
    unittest.main()
