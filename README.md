# glab-groups-shared

Shared GitHub Actions workflows and control-plane code for mirroring GitLab group
hierarchies into managed target namespaces.

## Runtime split

- Perl owns discovery, normalization, planning, target preparation, mirroring,
  verification, reporting, and resume handling.
- Python owns post-run analytics and tabular exports.

## Reusable workflow

Wrapper repositories call `.github/workflows/group-sync-core.yml` and pass:

- the shared repo/ref to check out
- the shared config repo/ref to check out
- the config subdirectory to load
- BWS access secrets for target GitLab credentials

The shared workflow uploads plan, result, report, CSV, JSON, and optional
Parquet artifacts on every run.

Mirroring runs in five parallel lanes. The deterministic plan is split into
batches of 25 repositories, and each lane processes every fifth batch so a
single slow or skipped repository does not block the entire run.

## Target namespace contract

Config files store relative target namespace paths. The runtime resolves the
real destination as:

- `GL_BASE_URL`
- `GL_GROUP_TOP_GLAB_OWNER`
- config `target_namespace_path`

and authenticates with:

- `GL_BRIDGE_FORK_USER_GLAB`
- `GL_PAT_FORK_GLAB_SVC`

## Ref selection

Each config directory exposes these defaults:

- `mirror_pristine_tar`: always mirror detected `pristine-tar` branch or tag
- `additional_branches`: extra branch names to mirror on every run when present
- `additional_tags`: extra tag names to mirror on every run when present
- `size_limit_bytes`: selected-ref budget, defaulting to 10 GiB
- `max_blob_bytes`: blob limit, defaulting to 100 MiB

## Validation

```sh
perl -c .github/scripts/glab_groups.pl
prove -Ilib tests/test_glab_groups.t
python3 -m unittest discover -s tests -p 'test_post_run_analytics.py'
```
