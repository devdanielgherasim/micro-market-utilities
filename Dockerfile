# =============================================================================
# CI toolchain base image.
#
# The aws/azure/gcp/terraform-aws cloud-CLI targets that used to build on top
# of this base stage were removed once GitLab CI (the only consumer of these
# images, via `ci-templates/`) was retired — GitHub Actions uses pinned setup
# actions directly (aws-actions/configure-aws-credentials, azure/login,
# google-github-actions/auth) instead of a shared toolbox image. This base
# stage (Java 21/Maven/Docker CLI/trivy/syft/cosign) currently has no
# consumer either; kept as-is pending a decision on whether to delete it too.
# =============================================================================

# ── base: JDK 21 + Maven + Docker CLI + supply-chain toolchain ───────────────
FROM eclipse-temurin:21-jdk-jammy AS base

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    jq \
    lsb-release \
    maven \
    software-properties-common \
    unzip && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /usr/share/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list && \
    apt-get update && apt-get install -y --no-install-recommends docker-ce-cli && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Supply-chain security toolchain (pinned + SHA256-verified).
# Versions and checksums verified 2026-07-03 against each project's upstream
# release tag and published checksums.txt; re-confirmed still current
# (no newer upstream tag) as of 2026-07-08. Do NOT float to `latest`.
#   Trivy  0.72.0  (aquasecurity/trivy)  — container/fs vulnerability scanner
#   Syft   1.46.0  (anchore/syft)        — SBOM generator (CycloneDX)
#   Cosign 3.1.1   (sigstore/cosign)     — keyless signing (Fulcio/Rekor)
# ---------------------------------------------------------------------------
ENV TRIVY_VERSION=0.72.0 \
    SYFT_VERSION=1.46.0 \
    COSIGN_VERSION=3.1.1

RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "${arch}" in \
      amd64) \
        TRIVY_ASSET="trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz"; \
        TRIVY_SHA="bbb64b9695866ce4a7a8f5c9592002c5961cab378577fa3f8a040df362b9b2ea"; \
        SYFT_ASSET="syft_${SYFT_VERSION}_linux_amd64.tar.gz"; \
        SYFT_SHA="d654f678b709eb53c393d38519d5ed7d2e57205529404018614cfefa0fb2b5ca"; \
        COSIGN_ASSET="cosign-linux-amd64"; \
        COSIGN_SHA="ae1ecd212663f3693ad9edf8b1a183900c9a52d3155ba6e354237f9a0f6463fc"; \
        ;; \
      arm64) \
        TRIVY_ASSET="trivy_${TRIVY_VERSION}_Linux-ARM64.tar.gz"; \
        TRIVY_SHA="2ca2c023109c2db6b2b77366b6717291452d4531167377d95c79547f0c8e3467"; \
        SYFT_ASSET="syft_${SYFT_VERSION}_linux_arm64.tar.gz"; \
        SYFT_SHA="9fafef4db4f032ce81008d3a1529985d41ceb6ccdf2b388c9ce2f1ed7d32082e"; \
        COSIGN_ASSET="cosign-linux-arm64"; \
        COSIGN_SHA="2ec865872e331c32fd12b08dae15332d3f92c0aa029219589684a4903ca85d11"; \
        ;; \
      *) echo "Unsupported architecture: ${arch}" >&2; exit 1 ;; \
    esac; \
    tmp="$(mktemp -d)"; cd "${tmp}"; \
    curl -fsSL -o "${TRIVY_ASSET}" \
      "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/${TRIVY_ASSET}"; \
    echo "${TRIVY_SHA}  ${TRIVY_ASSET}" | sha256sum -c -; \
    tar -xzf "${TRIVY_ASSET}" trivy; install -m 0755 trivy /usr/local/bin/trivy; \
    curl -fsSL -o "${SYFT_ASSET}" \
      "https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/${SYFT_ASSET}"; \
    echo "${SYFT_SHA}  ${SYFT_ASSET}" | sha256sum -c -; \
    tar -xzf "${SYFT_ASSET}" syft; install -m 0755 syft /usr/local/bin/syft; \
    curl -fsSL -o cosign \
      "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/${COSIGN_ASSET}"; \
    echo "${COSIGN_SHA}  cosign" | sha256sum -c -; \
    install -m 0755 cosign /usr/local/bin/cosign; \
    cd /; rm -rf "${tmp}"; \
    trivy --version; syft version; cosign version

CMD ["bash"]
