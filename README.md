# utilities

Builds the shared `java21-docker-azcli` CI tools image that every other
repo's pipeline runs its jobs in (`${CI_TOOLS_IMAGE}`), plus the reusable
GitLab CI templates (`ci-templates/`) that give catalog, orders, audit and
micro-market-frontend a common test -> scan -> build -> sign -> promote
pipeline shape.

## The CI tools image

`Dockerfile` builds `java21-docker-azcli` from `openjdk:21-slim`:

- **Java 21 + Maven** — for the three Quarkus services' `./mvnw` jobs.
- **Docker CLI** (`docker-ce-cli`, from Docker's own apt repo) — the image
  itself doesn't run a daemon; jobs use it against `docker:dind` or the
  runner's Docker socket.
- **AWS CLI, Azure CLI, Google Cloud CLI** — one image usable across all
  three clouds' OIDC/workload-identity login flows (see `build.sh` below and
  each service's own `build.sh`).
- **`jq`, Python 3** — used by the cloud-login scripts (parsing STS/WIF
  responses) and by `ci-templates`' `report-gate` job.

Frontend jobs that don't need this image (plain `npm`/`node` steps) run
directly on `node:20-alpine` instead — `${CI_TOOLS_IMAGE}` is only used for
this image's Docker-build/supply-chain/cloud-login steps.

### Supply-chain toolchain (pinned + checksum-verified)

The Dockerfile also bakes in the image-signing toolchain used by
`ci-templates/image-supply-chain.gitlab-ci.yml`, pinned to exact versions and
verified against published SHA256 checksums at build time (not floated to
`latest`, since this is the CI security toolchain itself):

| Tool | Version | Purpose |
|---|---|---|
| Trivy | `0.72.0` | Container image vulnerability scanning (CRITICAL-severity gate) |
| Syft | `1.46.0` | SBOM generation (CycloneDX) |
| Cosign | `3.1.1` | Keyless image signing + SBOM attestation (Sigstore Fulcio/Rekor) |

Each binary is downloaded from its project's GitHub releases, checksummed
with `sha256sum -c`, and installed to `/usr/local/bin`. Architecture is
detected at build time (`amd64`/`arm64` variants for all three tools).

## `ci-templates/`

Four reusable GitLab CI includes, consumed by other repos via a cross-project
include, e.g.:

```yaml
include:
  - project: microservices1691715/utilities
    ref: main
    file: ci-templates/java-service.gitlab-ci.yml   # or frontend.gitlab-ci.yml
```

- **`java-service.gitlab-ci.yml`** — top-level template for catalog/orders/audit.
  Declares the stage list (`test, scan, build, sign, promote`) and pulls in the
  two building blocks below. The consuming repo keeps its own `test` job
  (`./mvnw test`) and `build` job (`./build.sh`), just re-homed onto these
  stage names.
- **`frontend.gitlab-ci.yml`** — the same shape for micro-market-frontend
  (`npm` lint/test instead of `mvnw`).
- **`security-scan-gate.gitlab-ci.yml`** — includes GitLab's stock
  `Security/SAST`, `Security/Dependency-Scanning` and `Security/Secret-Detection`
  templates, then adds a `report-gate` job (stage `scan`) that parses the
  resulting `gl-*-report.json` artifacts with `jq` and **fails the pipeline**
  on any HIGH/CRITICAL finding — GitLab's free-tier templates only populate
  the MR widget, they never fail the pipeline on their own.
- **`image-supply-chain.gitlab-ci.yml`** — `.export-image-ref` (recomputes the
  pushed image reference/digest and writes a `build.env` dotenv for downstream
  jobs), `trivy-scan` (fail on CRITICAL), `sbom-generate` (Syft CycloneDX,
  kept as a pipeline artifact), `cosign-sign` (keyless sign + SBOM attest via
  a dedicated `SIGSTORE_ID_TOKEN` OIDC token, audience `sigstore` — distinct
  from the `GITLAB_OIDC_TOKEN` used for cloud registry login), `cosign-verify`
  (promote-stage gate: verifies both the image signature and the SBOM
  attestation against the expected GitLab Fulcio identity), and
  `trigger-deployment-promotion` (calls the GitLab Pipeline Trigger API to
  hand the verified image's tag to the `deployment` repo's promotion
  pipeline, since `deployment`'s own commit SHA has no relationship to the
  SHA a service image was actually tagged with).

Consuming repos need `CLOUD_PROVIDER`, `ENVIRONMENT`, `PROJECT_NAMESPACE`,
`CI_TOOLS_IMAGE`, and the cloud-specific auth variables their own `build.sh`
already requires (see each service's `.gitlab-ci.yml`).

## Building/pushing the image

`build.sh` mirrors each service's own `build.sh` login logic, but fans out
across all four app repos rather than building one image:

- Resolves `CONTAINER_REGISTRY_NAME` from `CLOUD_PROVIDER` (`aws`/`azure`/`gcp`)
  unless already set — AWS ECR (`<account>.dkr.ecr.<region>.amazonaws.com`),
  Azure ACR (`acr<namespace-no-hyphens><env>.azurecr.io`), or GCP Artifact
  Registry (`<region>-docker.pkg.dev/<project>`).
- Logs in per cloud: AWS via `aws sts assume-role-with-web-identity` (GitLab
  OIDC) + `aws ecr get-login-password`, Azure via `az login
  --service-principal --federated-token` (OIDC) or a client-secret fallback,
  GCP via a Workload Identity Federation credential file built from the
  GitLab OIDC token, then `gcloud auth configure-docker`.
- Exports the resolved registry/auth env vars plus `MAIN_SCRIPT_LOGIN=1`
  (so each service's own `build.sh` skips re-doing the login), then `cd`s up
  a level and runs `./build.sh` inside each of `audit catalog orders
  micro-market-frontend` (overridable via `$SERVICES`).

This repo's own `.gitlab-ci.yml` (separate from `ci-templates/`) builds and
pushes the `java21-docker-azcli` image itself: a single `build` stage,
GitLab Secret-Detection included, cloud-aware login logic inlined (same
aws/azure/gcp branches as above), tagged `$CI_COMMIT_SHA` and — on `main`
only — also `latest`. The job is `rules: when: manual`.

## Known inconsistencies

None currently open for this repo: `PROJECT_NAMESPACE` is consistently
`danielgherasim-microservices` in both `build.sh` and `.gitlab-ci.yml` here —
the historical `microservices1691715`/`...716`/`...717` namespace drift noted
elsewhere in this project's history has already been resolved in this repo.
