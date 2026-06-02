# Architecture

## Overview

`glab-groups-shared` is the reusable control plane for the Kali and Debian
wrapper repositories. The shared workflow checks out this repository and the
shared config repository, fetches target GitLab credentials from BWS, and then
runs the Perl and Python tooling in a deterministic order.

Target paths in config are stored relative to the target owner group. The
runtime composes full paths from `GL_BASE_URL`, `GL_GROUP_TOP_GLAB_OWNER`, and
the configured relative namespace path.

## Execution order

1. `plan`
2. `mirror` in five parallel lanes
3. `report`
4. `post_run_analytics.py`

The shared workflow creates one deterministic plan, uploads it as a run
artifact, and then starts a five-lane matrix. Each lane processes batches of 25
repositories with a stride of five, so lane 0 handles batches 0, 5, 10, lane 1
handles batches 1, 6, 11, and so on. The final report job downloads all lane
artifacts and aggregates them into one report, CSV, JSON analytics file, and
optional Parquet file.

## Planning model

The plan includes:

- source project id and full path
- target full path and target namespace id
- source inventory fields required for mirroring and verification
- deterministic action selection:
  - `create_project`
  - `update_project`
  - `mirror_only`
  - `skip`
  - `fail`

## Mirroring model

The mirror stage:

- creates or updates target projects before push
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

Per-repository failures are captured as skipped result rows and do not abort the
lane. Fatal configuration or credential failures still stop the workflow.
