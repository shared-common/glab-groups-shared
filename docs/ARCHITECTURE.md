# Architecture

## Overview

`glab-groups-shared` is the reusable control plane for the Kali, Debian, and
freedesktop wrapper repositories. The shared workflow checks out this
repository and the shared config repository, fetches target GitLab credentials
from BWS, and then runs the Perl and Python tooling in a deterministic order.

Target paths in config are stored relative to the target owner group. The
runtime composes full paths from `GL_BASE_URL`, `GL_GROUP_TOP_GLAB_OWNER`, and
the configured relative namespace path.

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

- updates existing target projects before push
- skips missing target projects instead of creating them
- skips archived source projects and archived existing target projects instead of
  mutating archive state
- never sets target group or project visibility
- discovers group inventory through direct-project and subgroup traversal rather
  than a single `include_subgroups=true` API query
- uses longer bounded retries for GitLab read requests during discovery to ride
  out transient 5xx and timeout failures from upstream GitLab/Varnish
- fetches only the selected branches and tags
- always includes the source default branch
- auto-detects `pristine-tar`
- applies configured additional branches and tags
- enforces a 10 GiB total selected-ref budget
- attempts LFS migration for blobs larger than 100 MiB before falling back to
  per-repository skip
- retries retryable Git and GitLab operations with bounded backoff
- verifies the resulting target project and refs

## Failure model

Expected policy skips, such as repositories above the selected-ref size budget,
are captured as skipped result rows. Unexpected per-repository exceptions are
captured as failed rows so artifacts and summaries are still produced; the final
report job then fails the workflow if any failed rows remain. Fatal
configuration or credential failures still stop the workflow before mirroring.
