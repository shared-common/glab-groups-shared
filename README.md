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

## Validation

```sh
perl -c .github/scripts/glab_groups.pl
prove -Ilib tests/test_glab_groups.t
python3 -m unittest discover -s tests -p 'test_post_run_analytics.py'
```
