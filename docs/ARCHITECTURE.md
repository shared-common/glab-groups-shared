# Architecture

## Overview

`glab-groups-shared` is the reusable control plane for the Kali, Debian,
freedesktop, small, OpenAI, NVIDIA, HashiCorp, Microsoft, Android, Chromium,
KDE, GNOME, and explicit-project wrapper repositories. The shared workflow
checks out this repository and the shared config repository, fetches target
GitLab credentials from BWS, and then runs the Perl and Python tooling in a
deterministic order.

Target paths in config are stored relative to the target owner group. The
runtime composes full paths from `GL_BASE_URL`, namespace `target_owner_path`,
and the configured relative namespace path.

Explicit project configs are the exception: they provide a full
`target_group_path`, and the runtime creates the destination as
`<target_group_path>/<name>` without deriving any target path segments from the
source repository URL. In namespace-based wrappers, `projects.yml` is also
authoritative for matching target paths: when an explicit project entry resolves
to the same target project path that namespace discovery would have produced,
the runtime skips the namespace-discovered copy and uses the explicit project
entry instead.

## Execution order

1. `plan`
2. `prepare-target` in batch jobs capped at ten concurrent jobs
3. `mirror` in matching batch jobs capped at ten concurrent jobs
4. `report`
5. `post_run_analytics.py`

The shared workflow creates one deterministic plan, uploads it as a run
artifact, and then builds a dynamic matrix capped at 250 prepare and mirror
jobs. Small plans still use one job per batch. Larger plans raise the effective
batch size until the plan fits within that cap, while GitHub Actions runs at
most ten jobs concurrently. Batch construction never splits one target subgroup
across multiple jobs. The prepare stage is best-effort per entry so one target
path failure does not block unrelated shards; the mirror stage retries target
creation/update during the real sync path and records final per-project
outcomes. The final report job downloads all batch artifacts, aggregates them
into one report, CSV, JSON analytics file, and optional Parquet file, then
publishes those artifacts back to the workflow run.

## Planning model

The plan includes:

- source project id and full path
- target full path and target namespace path
- source inventory fields required for mirroring and verification
- target-group-aware batches built from contiguous namespace ranges so each
  subgroup is created and mirrored in one job
- deterministic action selection:
  - `sync`
  - `skip`
  - `fail`

Planning no longer crawls the entire target namespace tree to precompute
project state. It keeps the target path only and defers live target group
resolution and missing subgroup creation to the target-preparation gate before
mirror fanout.

The plan job always performs live source discovery. The workflow does not
restore or reuse a persisted source inventory cache between runs.

## Mirroring model

The mirror stage:

- creates missing target projects and updates existing target projects before
  push
- skips source repositories when the upstream API marks them as archived
- does not mutate GitLab archive state as part of mirror execution
- never sets target group or project visibility
- discovers source inventory through GitLab group traversal, GitLab top-level
  group expansion, GitHub organization repository pagination, direct repository
  inspection for explicit project URLs, and cgit or Gitiles root scraping
  instead of relying on one source-specific integration path
- can use GitLab `include_subgroups=true` project enumeration for source group
  discovery when the config enables `gitlab_source_include_subgroups`
- resolves target groups by full path and caches the resulting GitLab IDs only
  in memory for the lifetime of each mirror job
- authenticates GitHub-source discovery and Git-over-HTTPS mirroring with the
  shared GitHub App by generating a JWT, resolving the source-account
  installation, and minting short-lived installation access tokens
- keeps non-GitHub explicit public project URLs on plain HTTPS git without
  source-auth injection, while explicit GitHub project URLs reuse the shared
  GitHub App auth flow during discovery and mirror execution
- retries repo-shaped root-discovered clone URLs with an appended `.git` suffix
  before failing when the human-facing URL does not expose refs over Git
- uses longer bounded retries for GitLab read requests during discovery to ride
  out transient 5xx and timeout failures from upstream GitLab/Varnish
- lets each config directory tune discovery/read retry counts separately from
  retryable git mirror operations
- fetches only the selected branches and tags
- always includes the source default branch in source-side selection
- mirrors the source default branch into target `gitlab/mcr/main`
- force-syncs configured additional branches to same-name target branches
- force-syncs configured additional tags to same-name target tags
- also force-syncs the source default branch by name when that branch is
  explicitly listed in `additional_branches`
- auto-detects `pristine-tar`
- applies configured additional branches and tags
- bootstraps target-only `mcr/main`, `mcr/feature/init`, `mcr/staging`, and
  `mcr/release` branches when missing
- sets target `mcr/main` as the default branch when bootstrap succeeds
- reconciles managed branch protection so only the branches configured by
  `target_branches_protect` remain protected
- enforces a 9 GiB packed selected-ref storage budget that better matches GitLab
  repository storage behavior than an uncompressed object-size sum
- attempts LFS migration for blobs larger than 100 MiB before falling back to
  per-repository skip
- retries retryable Git and GitLab operations with bounded backoff
- verifies the resulting target project and refs

## Failure model

Expected policy skips, such as repositories above the selected-ref size budget,
are captured as skipped result rows. Unexpected per-repository exceptions are
captured as failed rows with error details so artifacts and summaries are still
produced and the rest of the run keeps going. Fatal
configuration or credential failures still stop the workflow before mirroring.
