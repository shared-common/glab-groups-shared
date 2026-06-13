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

1. `bootstrap`
2. `discover` matrix
3. `plan`
4. `mirror`
5. `report`
6. `post_run_analytics.py`

The shared workflow first resolves config metadata, then fans source discovery
out across a dynamic matrix capped at 250 jobs, merges those discovery shards
into one deterministic plan, and finally fans mirror execution out again across
up to 250 jobs. GitHub Actions still runs at most five mirror jobs concurrently.
Batch construction now rebalances targets across the final mirror shards instead
of letting a large tail accumulate in the last job. The mirror stage skips
already-synced repositories with `git ls-remote`, retries target
creation/update only when the target repo is missing or later write steps need
API-backed reconciliation, and records final per-project outcomes. The final
report job downloads all batch artifacts, aggregates them into one report, CSV,
JSON analytics file, and optional Parquet file, then publishes those artifacts
back to the workflow run.

## Planning model

The plan includes:

- source project id and full path
- target full path and target namespace path
- source inventory fields required for mirroring and verification
- target-aware batches built from the merged discovery output and redistributed
  to keep the final mirror shards close in size
- deterministic action selection:
  - `sync`
  - `skip`
  - `fail`

Planning no longer crawls the entire target namespace tree to precompute
project state. It keeps the target path only and defers live target group
resolution, missing subgroup creation, and ref-by-ref target checks to the
mirror jobs.

The workflow always performs live source discovery. It does not restore or
reuse a persisted source inventory cache between runs, but it now parallelizes
discovery before building the final plan.

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
- reads target repository refs with `git ls-remote` over the `glab-forks`
  deploy token instead of GitLab project-read API calls
- fetches only the selected branches and tags
- always includes the source default branch in source-side selection
- mirrors the source default branch into the managed target branch named by the
  BWS secret `GIT_BRANCH_GLAB_FORKS`
- force-syncs configured additional branches to same-name target branches
- force-syncs configured additional tags to same-name target tags
- also force-syncs the source default branch by name when that branch is
  explicitly listed in `additional_branches`
- auto-detects `pristine-tar`
- applies configured additional branches and tags
- skips mirror execution entirely when all selected source refs already match
  the target repository
- reconciles only the explicitly configured target branch protections
- enforces a 9 GiB packed selected-ref storage budget that better matches GitLab
  repository storage behavior than an uncompressed object-size sum
- attempts LFS migration for blobs larger than 100 MiB before falling back to
  per-repository skip
- retries retryable Git and GitLab operations with bounded backoff
- skips redundant target verification reads after push

## Failure model

Expected policy skips, such as repositories above the selected-ref size budget,
are captured as skipped result rows. Unexpected per-repository exceptions are
captured as failed rows with error details so artifacts and summaries are still
produced and the rest of the run keeps going. Fatal
configuration or credential failures still stop the workflow before mirroring.
