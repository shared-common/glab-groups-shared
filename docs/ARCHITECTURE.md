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
2. `mirror`
3. `report`
4. `post_run_analytics.py`

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
- verifies the resulting target project and refs

## Failure model

Per-repository failures are captured as result rows and do not abort the entire
job. Fatal configuration or credential failures still stop the workflow.
