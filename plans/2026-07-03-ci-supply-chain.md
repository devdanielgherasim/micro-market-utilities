---
title: CI supply-chain & security-scan suite (Phase 9 Task 25)
status: complete
created: 2026-07-03
updated: 2026-07-04
owner: ci-supply-chain agent
parent_plan: ../../plans/2026-07-03-multicloud-platform-overhaul.md (Task 25)
note: >
  Parent plan file is being edited concurrently by two other Phase-9/Phase-10
  agents (Task 26 etc.) — do NOT edit it directly from this sub-plan's context.
  The coordinator merges this sub-plan's summary into the parent plan itself.
---

# CI supply-chain & security-scan suite

Implements Task 25 of the multi-cloud overhaul: shared GitLab CI templates in
`utilities/ci-templates/` plus security toolchain in `utilities/Dockerfile`,
rewiring catalog/orders/audit/micro-market-frontend onto them.

## Scope (repos I own — touch ONLY these)
- `utilities/` (Dockerfile + new `ci-templates/`)
- `catalog/.gitlab-ci.yml`, `orders/.gitlab-ci.yml`, `audit/.gitlab-ci.yml`
- `micro-market-frontend/.gitlab-ci.yml`

Do NOT touch: infrastructure, kubernetes-infrastructure, deployment, platform-gitops,
any `build.sh`, or GitOps image write-back (that is Phase 10 Task 29).

## Pinned tool versions (verified 2026-07-03 against upstream tags + checksums.txt)
- Trivy **v0.72.0** (aquasecurity/trivy) — latest 0.72.x; only patch in series.
  - amd64 sha256 `bbb64b9695866ce4a7a8f5c9592002c5961cab378577fa3f8a040df362b9b2ea` (trivy_0.72.0_Linux-64bit.tar.gz)
  - arm64 sha256 `2ca2c023109c2db6b2b77366b6717291452d4531167377d95c79547f0c8e3467` (trivy_0.72.0_Linux-ARM64.tar.gz)
- Syft **v1.46.0** (anchore/syft) — latest 1.46.x; only patch in series.
  - amd64 sha256 `d654f678b709eb53c393d38519d5ed7d2e57205529404018614cfefa0fb2b5ca` (syft_1.46.0_linux_amd64.tar.gz)
  - arm64 sha256 `9fafef4db4f032ce81008d3a1529985d41ceb6ccdf2b388c9ce2f1ed7d32082e` (syft_1.46.0_linux_arm64.tar.gz)
- Cosign **v3.1.1** (sigstore/cosign) — latest 3.1.x.
  - amd64 sha256 `ae1ecd212663f3693ad9edf8b1a183900c9a52d3155ba6e354237f9a0f6463fc` (cosign-linux-amd64)
  - arm64 sha256 `2ec865872e331c32fd12b08dae15332d3f92c0aa029219589684a4903ca85d11` (cosign-linux-arm64)

## Key decisions
- cosign keyless id_token named **SIGSTORE_ID_TOKEN** (aud `sigstore`) — GitLab's
  official flow; cosign auto-detects it from env, no `--identity-token` needed.
  Deviates from spec's literal `GITLAB_OIDC_TOKEN` name (which already exists on
  build jobs with aud `https://gitlab.com` and must not be clobbered). Documented.
- cosign v3: image `sign`/`attest --type cyclonedx`/`verify` flags unchanged from
  v2; the v3 `--bundle`/`--new-bundle-format` deprecations affect only sign-blob,
  which we don't use. `--yes` used to skip the transparency-log confirm prompt.
- verify cert-identity constructed from CI vars:
  `${CI_PROJECT_URL}//.gitlab-ci.yml@refs/heads/${CI_COMMIT_BRANCH}`,
  issuer `${CI_SERVER_URL}` (= https://gitlab.com). Regexp fallback also provided.
- Cross-project include base: `project: microservices1691715/utilities, ref: main`.
- IMAGE_REF/digest passed build→sign→promote via `artifacts: reports: dotenv`.

## Tasks
- [x] T0. Research versions/checksums/cosign-v3 flags; write plan.
- [x] T1. utilities/Dockerfile: pinned trivy+syft+cosign with sha256 verification.
- [x] T2. ci-templates/security-scan-gate.gitlab-ci.yml (SAST+Dep+Secret + report-gate jq HIGH/CRITICAL).
- [x] T3. ci-templates/image-supply-chain.gitlab-ci.yml (trivy-scan, sbom-generate, cosign-sign, cosign-verify).
- [x] T4. ci-templates/java-service.gitlab-ci.yml + frontend.gitlab-ci.yml (stages + includes).
- [x] T5. Rewire catalog/orders/audit/frontend .gitlab-ci.yml (includes, stages, dotenv on build job).
- [x] T6. Verification: YAML parse all files, git diff --check, confirm no out-of-scope repos touched.

## Verification log (2026-07-03)
- YAML: all 8 CI files (4 templates + catalog/orders/audit/frontend) parsed clean
  with Python `yaml.safe_load` + a registered `!reference` constructor. Top-level
  keys as expected; hidden `.` jobs present in image-supply-chain.
- GCP heredoc: extracted `.registry-login` shell from the parsed YAML and confirmed
  the `<<EOF` terminator de-indents to column 0 (valid heredoc) after YAML strips
  the block-scalar indentation. HEREDOC CHECK: PASS.
- `git diff --check`: clean in utilities, catalog, orders, audit, micro-market-frontend.
- catalog/orders/audit `.gitlab-ci.yml` md5-identical after copy (9d7087c7...).
- Out-of-scope repos (infrastructure/kubernetes-infrastructure/deployment/platform-gitops):
  not touched (no ci-supply-chain plan or ci-templates added there).
- NOT run: live GitLab CI lint / pipeline execution (no GitLab lint API from this
  host); `docker build` of the Dockerfile (no daemon here) -- checksum verification
  runs on the CI runner at build time. Trivy/Syft/Cosign install steps are pinned
  with the exact upstream SHA256s recorded above.

## Files created/changed (all LOCAL, not pushed)
- utilities/Dockerfile (M) -- trivy 0.72.0 + syft 1.46.0 + cosign 3.1.1, arch-aware SHA256-verified
- utilities/ci-templates/security-scan-gate.gitlab-ci.yml (new)
- utilities/ci-templates/image-supply-chain.gitlab-ci.yml (new)
- utilities/ci-templates/java-service.gitlab-ci.yml (new)
- utilities/ci-templates/frontend.gitlab-ci.yml (new)
- catalog/.gitlab-ci.yml, orders/.gitlab-ci.yml, audit/.gitlab-ci.yml (M, identical)
- micro-market-frontend/.gitlab-ci.yml (M)
- utilities/plans/2026-07-03-ci-supply-chain.md (this file)
