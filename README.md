# glab-groups-shared

Shared GitHub Actions workflows and control-plane code for mirroring public
source-group hierarchies, public repository collections, and explicit
single-project sources into managed target namespaces.

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

Config directories can use `.json`, `.yml`, or `.yaml` files.

Mirroring runs through deterministic batch shards with `max-parallel: 5`. Small
plans still create one job per batch; larger plans cap the matrix at 256 jobs
and let each shard process every 256th batch so GitHub Actions matrix limits are
not exceeded.

## Supported source roots

Config `source_group_url` values can point at:

- a GitLab group URL with an explicit path, such as `https://gitlab.com/xanmod`
- a GitLab instance root URL, such as `https://invent.kde.org`, which expands
  into the current public top-level groups beneath the configured target prefix
- a GitHub organization URL, such as `https://github.com/labwc`, which mirrors
  the current organization repositories using the shared GitHub App credentials
  from `GH_ORG_SHARED_APP_ID` and `GH_ORG_SHARED_APP_PEM`
- a cgit root URL, such as `https://git.netfilter.org`, which mirrors the
  current root-level repositories discovered from the cgit index page

Config `source_project_url` values can point at:

- a single GitLab or GitHub repository URL, such as
  `https://gitlab.com/WhyNotHugo/darkman`
- a public Git-over-HTTPS repository URL, such as
  `https://chromium.googlesource.com/chromiumos/user-recovery-tools`
- a public cgit-style repository URL, such as
  `https://git.code.sf.net/p/gptfdisk/code`

## Target namespace contract

Config files store relative target namespace paths. The runtime resolves the
real destination as:

- `GL_BASE_URL`
- config `target_owner_path`
- config `target_namespace_path`

and authenticates with:

- `GL_BRIDGE_FORK_USER_GLAB`
- `GL_PAT_GROUP_KALI_SVC` for `glab-groups-kali`
- `GL_PAT_GROUP_DEBIAN_SVC` for `glab-groups-debian`
- `GL_PAT_GROUP_FREEDESKTOP_SVC` for `glab-groups-freedesktop`
- `GL_PAT_GROUP_SMALL_SVC` for `glab-groups-small`
- `GL_PAT_GROUP_OPENAI_SVC` for `glab-groups-openai`
- `GL_PAT_GROUP_NVIDIA_SVC` for `glab-groups-nvidia`
- `GL_PAT_GROUP_KDE_SVC` for `glab-groups-kde`
- `GL_PAT_GROUP_GNOME_SVC` for `glab-groups-gnome`
- `GL_PAT_GROUP_PROJ_SVC` for `glab-groups-projects`

Target group and project visibility is not created, updated, or finalized by
this workflow. Configure visibility directly on the target GitLab owner/group
outside the mirror run to avoid denied metadata writes and rate-limit pressure.

Explicit single-project configs instead provide a full `target_group_path`
such as `glab-forks/labwc`; the runtime creates or updates the target project
as `<target_group_path>/<name>` without deriving target path segments from the
source repository URL.

Target project deletion stays outside this workflow. The shared runtime creates
missing target projects, updates existing target project metadata, and skips
archived sources.

The planning phase inventories existing target namespace trees but does not
pre-create missing target groups. Missing target namespace paths are resolved
only when a mirror or explicit target-preparation step actually needs them.

## Ref selection

Each config directory exposes these defaults:

- `mirror_pristine_tar`: always mirror detected `pristine-tar` branch or tag
- `gitlab_source_include_subgroups`: optional GitLab source discovery mode that
  uses `include_subgroups=true` instead of subgroup-by-subgroup traversal
- `read_retry_attempts`: retry count for plan/discovery GitLab API reads
- `read_retry_backoff_seconds`: backoff for plan/discovery GitLab API reads
- `additional_branches`: extra branch names to mirror on every run when present
- `additional_tags`: extra tag names to mirror on every run when present
- `retry_attempts`: retry count for retryable git mirror operations
- `retry_backoff_seconds`: backoff for retryable git mirror operations
- `size_limit_bytes`: selected-ref packed storage budget, defaulting to 9 GiB
- `max_blob_bytes`: blob limit, defaulting to 100 MiB

The source default branch is mirrored to the managed target branch
`gitlab/mcr/main` instead of a target-side `main` branch. After the synced
branch lands, the runtime bootstraps these target-only branches when missing:

- `mcr/main` from `gitlab/mcr/main` and sets it as the target default branch
- `mcr/feature/init` from `mcr/main`
- `mcr/staging` from `mcr/main`
- `mcr/release` from `mcr/main`

After bootstrap, the runtime reconciles protection for the managed target
branches so that only the branch names listed in the config entry
`target_branches_protect` remain protected. The checked-in configs currently
protect `gitlab/mcr/main`.

Those `mcr/*` branches are one-shot target bootstrap branches. They are not
force-synced from source on later runs.

Plan runs also reuse a cached normalized source inventory artifact between
workflow runs when the cache is still fresh. The shared workflow currently treats
an inventory cache younger than 18 hours as reusable and rewrites the cache
after rediscovery.

## Validation

```sh
perl -c .github/scripts/glab_groups.pl
prove -Ilib tests/test_glab_groups.t
python3 -m unittest discover -s tests -p 'test_post_run_analytics.py'
```
