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

The shared workflow uploads discovery, plan, result, report, CSV, JSON, and
optional Parquet artifacts on every run. Source inventory is rebuilt live on
each run through sharded discovery jobs; target GitLab group resolution stays
path-based and in-memory for the lifetime of each mirror job.

Config directories can use `.json`, `.jsonl`, `.yml`, or `.yaml` files.
`projects.yml` is the authoritative explicit-project config for a wrapper. In
namespace-based wrappers, any target path defined in `projects.yml` overrides
namespace discovery for that one project: discovery skips the
namespace-discovered copy and the explicit project entry becomes the source of
truth for source URL and per-project policy. The dedicated
`groups.jsonl` allowlist is only for single-namespace GitLab instance-root
wrappers; it accepts one JSON string path per line and limits discovery to the
checked-in top-level source groups instead of expanding the whole instance. If
one of those configured top-level groups disappears upstream, discovery records
the missing group as a warning, skips that target path for the current run, and
continues planning the remaining mirror work.

Mirroring runs through deterministic discovery and mirror shards with the
checked-in `max-parallel: 5` cap. Discovery fans out across up to 250 matrix
jobs, the final plan is built from the merged discovery shards, and mirror
batches are rebalanced so the final plan stays within 250 jobs with a much more
even per-shard target count.

## Supported source roots

Config `source_group_url` values can point at:

- a GitLab group URL with an explicit path, such as `https://gitlab.com/xanmod`
- a GitLab instance root URL, such as `https://invent.kde.org`, which expands
  into the current public top-level groups beneath the configured target prefix,
  or into the checked-in subset listed in `groups.jsonl` when that allowlist is
  present for the wrapper
- a GitHub organization URL, such as `https://github.com/labwc`, which mirrors
  the current organization repositories using the shared GitHub App credentials
  from `GH_ORG_READ_APP_ID` and `GH_ORG_READ_APP_PEM`
- a cgit root URL, such as `https://git.netfilter.org`, which mirrors the
  current root-level repositories discovered from the cgit index page
- a Gitiles root URL, such as `https://chromium.googlesource.com` or
  `https://android.googlesource.com`, which mirrors the current repositories
  discovered from the Gitiles root index while preserving nested repository
  paths beneath the configured target prefix

Config `source_project_url` values can point at:

- a single GitLab or GitHub repository URL, such as
  `https://gitlab.com/WhyNotHugo/darkman`
- a SourceHut Git-over-HTTPS repository URL, such as
  `https://git.sr.ht/~kennylevinsen/seatd`
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

- `GL_PAT_GROUP_KALI_SVC` for `glab-groups-kali`
- `GL_PAT_GROUP_ANDROID_SVC` for `glab-groups-android`
- `GL_PAT_GROUP_CHROMIUM_SVC` for `glab-groups-chromium`
- `GL_PAT_GROUP_DEBIAN_SVC` for `glab-groups-debian`
- `GL_PAT_GROUP_FREEDESKTOP_SVC` for `glab-groups-freedesktop`
- `GL_PAT_GROUP_SMALL_SVC` for `glab-groups-small`
- `GL_PAT_GROUP_HASHICORP_SVC` for `glab-groups-hashicorp`
- `GL_PAT_GROUP_MICROSOFT_SVC` for `glab-groups-microsoft`
- `GL_PAT_GROUP_OPENAI_SVC` for `glab-groups-openai`
- `GL_PAT_GROUP_NVIDIA_SVC` for `glab-groups-nvidia`
- `GL_PAT_GROUP_KDE_SVC` for `glab-groups-kde`
- `GL_PAT_GROUP_GNOME_SVC` for `glab-groups-gnome`
- `GL_PAT_GROUP_PROJ_SVC` for `glab-groups-projects`

Target group and project visibility is not created, updated, or finalized by
this workflow. Configure visibility directly on the target GitLab owner/group
outside the mirror run to avoid denied admin writes and unnecessary API churn.

Explicit single-project configs instead provide a full `target_group_path`
such as `glab-forks/labwc`; the runtime creates or updates the target project
as `<target_group_path>/<name>` without deriving target path segments from the
source repository URL.

Target project deletion stays outside this workflow. The shared runtime creates
missing target projects, updates existing target project metadata, and skips
archived sources.

Managed groups are reconciled to:

- `shared_runners_setting=disabled_and_unoverridable`
- `project_creation_level=maintainer`
- `subgroup_creation_level=maintainer`

Managed projects are reconciled to:

- `group_runners_enabled=false`
- `shared_runners_enabled=false`

The planning phase does not pre-create missing target groups or recursively
inventory the full target namespace tree. It builds target-aware batches from
the merged discovery output so mirror work is spread more evenly across shards.
Target group IDs are resolved live from the configured path and cached only
inside the current job.

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

Configured additional branches are force-synced to same-name target branches.
Configured additional tags are force-synced to same-name target tags. The
source default branch is always mirrored to the managed target branch named by
the BWS secret `GIT_BRANCH_GLAB_FORKS`; if that same source branch is also
listed in `additional_branches`, it is mirrored both to the managed target
branch and to its same-name target branch.

The shared runtime no longer creates extra target-only `mcr/*` branches, no
longer resets the project default branch during mirror runs, and no longer
reconciles a default protected-branch set on every target project. When an
explicit `projects.yml` entry sets `additional_branches`, those same-name
target branches are protected after push. Explicit project entries may also set
`target_branches_protect` for any extra protected target branches that should
not be implied by mirrored source branches.

Plan runs always use live source discovery. The workflow no longer restores or
reuses a persisted source inventory cache between runs, and it no longer
serializes all discovery into one job. Target preparation is best-effort per
repository: the mirror stage compares source and target refs with `git
ls-remote`, skips already-synced repositories before any target API work, and
uses the `glab-forks` deploy token for target-side read checks.

## Validation

Repo-native CI in `validate-shared.yml` validates both this shared runtime and
the current checked-in `shared-common/gh-actions-cfg` config repo, so config
key changes stay centralized instead of being rechecked separately in every
wrapper repository.

```sh
perl -c .github/scripts/glab_groups.pl
prove -Ilib tests/test_glab_groups.t
python3 -m unittest discover -s tests -p 'test_*.py'
```
