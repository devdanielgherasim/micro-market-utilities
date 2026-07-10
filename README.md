# utilities

Hosts the reusable GitHub Actions building blocks — composite actions and
`workflow_call` reusable workflows — that give catalog, orders, audit and
micro-market-frontend a common test -> scan -> build -> sign -> promote
pipeline shape.

CI/CD for this project migrated from GitLab to GitHub Actions (see
`Sources/plans/2026-07-08-gitlab-to-github-migration.md`, complete). The
GitLab-only pieces that used to live here — `.gitlab-ci.yml`, `ci-templates/`
(4 reusable GitLab CI includes), and the `Dockerfile`'s `aws`/`azure`/`gcp`/
`terraform-aws` CI-toolbox targets plus the `build.sh` that built/pushed
them — have been removed. GitHub-hosted runners use pinned setup actions
directly (`aws-actions/configure-aws-credentials`, `azure/login`,
`google-github-actions/auth`, `aquasecurity/trivy-action`,
`anchore/sbom-action`, `sigstore/cosign-installer`) instead of a shared
toolbox image, so no replacement image is needed.

## `.github/actions/` (composite actions)

- **`resolve-image-ref`** — computes the pushed image reference/digest from
  each service's `build.sh` output and exposes it as step outputs.
- **`cloud-registry-login`** — wraps `aws-actions/configure-aws-credentials`
  / `azure/login` / `google-github-actions/auth` behind one cloud-agnostic
  interface; derives the registry host per cloud when not supplied.
- **`cosign-verify-identity`** — derives the GitHub-format Fulcio
  identity/issuer shared by the sign and verify steps.

## `.github/workflows/` (reusable, `workflow_call`)

- **`image-supply-chain.yml`** — `trivy-scan` (fail on CRITICAL, with an
  opt-in `trivy-ignore-cves` input for documented lab-scope exceptions),
  `sbom-generate` (Syft CycloneDX), `cosign-sign` (keyless sign + SBOM
  attestation via Sigstore, gated by GitHub's own OIDC token — no separate
  audience token needed the way GitLab required one), `cosign-verify`, and
  `trigger-deployment-promotion` (`repository_dispatch` to the `deployment`
  repo, gated by a `trigger-promotion` input).
- **`security-scan-gate.yml`** — CodeQL with a severity gate (polls the code
  scanning alerts API and fails on HIGH/CRITICAL), `dependency-review`
  (PR-only), and `gitleaks`.

Consuming repos need `CLOUD_PROVIDER`, `ENVIRONMENT`, `PROJECT_NAMESPACE`
(GitHub Actions variables) and the cloud-specific auth secrets their own
`ci.yml` requires — see each service's `.github/workflows/ci.yml`.

## `scripts/`

- **`bootstrap.sh`** — one-time cloud foundation setup: AWS IAM
  deploy user + OIDC role + S3 Terraform state bucket, or Azure service
  principal + Terraform state backend + ACR naming. Historically also
  provisioned GitLab CI/CD variables and a GitLab-federated AWS IAM role;
  that variable-pushing logic was removed once GitLab CI was retired, but
  the AWS IAM role it creates is still named `gitlab-oidc-${PROJECT_NAMESPACE}`
  — that's the same live role GitHub Actions authenticates through today
  (see the script's header comment), so the name wasn't changed.
- **`bootstrap-github.sh`** — the live GitHub Actions credential bootstrap:
  sets per-repo secrets/variables, distributes `DEPLOYMENT_DISPATCH_PAT`,
  and merges a GitHub OIDC trust statement into the AWS role `bootstrap.sh`
  creates (must be run after `bootstrap.sh` on a fresh cloud).
- **`finalize-github-repo.sh`** — per-repo GitHub cutover helper: public
  visibility, secret scanning + push protection, `main` branch protection.
- **`generate-diagrams.sh`** — regenerates the architecture diagrams under
  `docs/`.

## Known inconsistencies

None currently open for this repo: `PROJECT_NAMESPACE` is consistently
`danielgherasim-microservices` across the scripts and workflows here.
