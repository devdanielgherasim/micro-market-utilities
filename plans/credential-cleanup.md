---
status: abandoned
created: 2026-07-03
updated: 2026-07-03
owner: codex
repo: utilities
objective: Remove committed credentials from utility build orchestration and make image build login provider-aware.
superseded-by: ../../plans/2026-07-03-multicloud-platform-overhaul.md
---

> **Superseded 2026-07-03**: absorbed into the workspace-root plan
> `Sources/plans/2026-07-03-multicloud-platform-overhaul.md` (its Phase 0/1 covers the
> remaining credential work; the build.sh rewrite done here is kept and committed there).

# Utility Credential Cleanup

## Context
- `utilities/build.sh` orchestrates cross-service image builds.
- The previous script contained hardcoded Azure credentials and a fixed service list.
- AWS is the target provider for the current rebuild; Azure remains an optional compatibility path.

## Tasks
- [x] Remove hardcoded Azure credentials from `build.sh`.
- [x] Make registry login provider-aware for AWS ECR and Azure ACR.
- [ ] Validate image build flow after app build scripts are made AWS/ECR-aware.

## Decisions
- Require credentials through environment variables only.
- Use `SERVICES` to select services, defaulting to all four application workloads.

## Validation
- Git Bash `bash -n` passed for `build.sh`.
- Secret-pattern scan found no remaining live-looking AWS session key, GitLab PAT, or hardcoded Azure secret patterns in this repo.
- End-to-end image build validation is pending until application build scripts are made AWS/ECR-aware.

## Next Steps
- Update application build scripts and CI to publish AWS ECR images by immutable commit SHA.
