# Architecture

## Overview

`glab-groups-shared` is the reusable control plane for the Kali, Debian,
freedesktop, small, KDE, and GNOME wrapper repositories. The shared workflow
checks out this repository and the shared config repository, fetches target
GitLab credentials from BWS, and then runs the Perl and Python tooling in a
deterministic order.

Target paths in config are stored relative to the target owner group. The
runtime composes full paths from `GL_BASE_URL`, namespace `target_owner_path`,
and the configured relative namespace path.

## Execution order

1. `plan`
2. `mirror` in batch jobs capped at five concurrent jobs
3. `report`
4. `post_run_analytics.py`

The shared workflow creates one deterministic plan, uploads it as a run
artifact, and then builds a dynamic matrix capped at 256 mirror jobs. Small
plans still use one job per batch. Larger plans use shard starts and strides so
each job processes a deterministic subset of batches while GitHub Actions runs
at most five jobs concurrently. The final report job downloads all batch
artifacts and aggregates them into one report, CSV, JSON analytics file, and
optional Parquet file.

## Planning model

The plan includes:

- source project id and full path
- target full path and target namespace id
- source inventory fields required for mirroring and verification
- deterministic action selection:
  - `update_project`
  - `mirror_only`
  - `skip`
  - `fail`

## Mirroring model

The mirror stage:

- creates missing target projects and updates existing target projects before
  push
- skips source repositories when the upstream API marks them as archived
- does not mutate GitLab archive state as part of mirror execution
- never sets target group or project visibility
- discovers source inventory through GitLab group traversal, GitLab top-level
  group expansion, GitHub organization repository pagination, and cgit root
  scraping instead of relying on one source-specific integration path
- authenticates GitHub-source discovery and Git-over-HTTPS mirroring with the
  shared GitHub App by generating a JWT, resolving the source-account
  installation, and minting short-lived installation access tokens
- uses longer bounded retries for GitLab read requests during discovery to ride
  out transient 5xx and timeout failures from upstream GitLab/Varnish
- fetches only the selected branches and tags
- always includes the source default branch in source-side selection
- mirrors the source default branch into target `gitlab/mcr/main`
- auto-detects `pristine-tar`
- applies configured additional branches and tags
- bootstraps target-only `mcr/main`, `mcr/feature/init`, `mcr/staging`, and
  `mcr/release` branches when missing
- sets target `mcr/main` as the default branch when bootstrap succeeds
- protects target `mcr/staging` and `mcr/release`
- enforces a 10 GiB total selected-ref budget
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
