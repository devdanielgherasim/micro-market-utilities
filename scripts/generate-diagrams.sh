#!/usr/bin/env bash
# generate-diagrams.sh — pull Terraform state from S3 and produce architecture diagrams.
#
# Outputs per layer (infrastructure + kubernetes-infrastructure):
#   - <layer>.png  — static architecture diagram via inframap + graphviz
#   - <layer>.svg  — same diagram in SVG
#   - <layer>/     — interactive Rover HTML report
#
# Requirements: aws CLI, Docker
# Usage:
#   ./generate-diagrams.sh
#   ./generate-diagrams.sh --env dev --output docs/diagrams
#   ./generate-diagrams.sh --env dev --format png        # skip rover HTML
#   ./generate-diagrams.sh --env dev --format html       # skip static images

set -euo pipefail

# ── colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── defaults ──────────────────────────────────────────────────────────────────
ENVIRONMENT="${ENVIRONMENT:-dev}"
AWS_REGION="${AWS_REGION:-eu-central-1}"
OUTPUT_DIR="docs/diagrams"
FORMAT="all"   # all | png | html

# ── arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)      ENVIRONMENT="$2";  shift 2 ;;
    --output)   OUTPUT_DIR="$2";   shift 2 ;;
    --format)   FORMAT="$2";       shift 2 ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# //'
      exit 0 ;;
    *) die "Unknown option: $1. Use --env, --output, --format, or --help." ;;
  esac
done

[[ "$FORMAT" =~ ^(all|png|html)$ ]] || die "Invalid --format '$FORMAT'. Must be: all, png, html."

# ── prerequisites ─────────────────────────────────────────────────────────────
command -v aws    >/dev/null 2>&1 || die "aws CLI not installed."
command -v docker >/dev/null 2>&1 || die "Docker not installed or not running."

docker info >/dev/null 2>&1 || die "Docker daemon is not running."

# ── resolve bucket ────────────────────────────────────────────────────────────
info "Checking AWS credentials..."
CALLER=$(aws sts get-caller-identity 2>/dev/null) \
  || die "AWS credentials not configured. Run 'aws configure' or export AWS_* vars."
AWS_ACCOUNT_ID=$(echo "$CALLER" | grep -o '"Account": *"[^"]*"' | grep -o '[0-9]*')

STATE_BUCKET="${AWS_TF_STATE_BUCKET:-terraform-state-${AWS_ACCOUNT_ID}-${AWS_REGION}}"
success "Account: ${AWS_ACCOUNT_ID}  Region: ${AWS_REGION}  Bucket: ${STATE_BUCKET}"

# ── verify bucket exists ──────────────────────────────────────────────────────
aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null \
  || die "Bucket '$STATE_BUCKET' not found or not accessible. Run bootstrap.sh first."

# ── state file locations ──────────────────────────────────────────────────────
declare -A LAYERS=(
  [infrastructure]="aws/${ENVIRONMENT}/terraform.tfstate"
  [kubernetes-infrastructure]="kubernetes/aws/${ENVIRONMENT}/terraform.tfstate"
)

# ── output directory ──────────────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"

# ── Docker image references ───────────────────────────────────────────────────
INFRAMAP_IMAGE="cycloidio/inframap:latest"
GRAPHVIZ_IMAGE="nshine/dot:latest"
ROVER_IMAGE="im2nguyen/rover:latest"

pull_image() {
  local image="$1"
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    info "Pulling $image..."
    docker pull --quiet "$image"
  fi
}

# ── per-layer generation ──────────────────────────────────────────────────────
GENERATED=()

for LAYER in "${!LAYERS[@]}"; do
  STATE_KEY="${LAYERS[$LAYER]}"
  LOCAL_STATE_FILE="/tmp/tfstate-${LAYER}-${ENVIRONMENT}.json"
  LAYER_OUTPUT="${OUTPUT_DIR}/${LAYER}"

  echo
  echo "────────────────────────────────────────────────────────"
  info "Layer: ${LAYER}  (${ENVIRONMENT})"
  info "State key: s3://${STATE_BUCKET}/${STATE_KEY}"
  echo "────────────────────────────────────────────────────────"

  # Download state
  info "Downloading state from S3..."
  if ! aws s3 cp \
        "s3://${STATE_BUCKET}/${STATE_KEY}" \
        "$LOCAL_STATE_FILE" \
        --region "$AWS_REGION" 2>/dev/null; then
    warn "State file not found for '${LAYER}' — skipping (has the apply run yet?)."
    continue
  fi

  RESOURCE_COUNT=$(python3 -c "
import json, sys
data = json.load(open('$LOCAL_STATE_FILE'))
resources = data.get('resources', [])
managed = [r for r in resources if r.get('mode') == 'managed']
print(len(managed))
" 2>/dev/null || echo "?")
  success "State downloaded — ${RESOURCE_COUNT} managed resources"

  mkdir -p "$LAYER_OUTPUT"

  # ── static diagram via inframap + graphviz ──────────────────────────────
  if [[ "$FORMAT" == "all" || "$FORMAT" == "png" ]]; then
    pull_image "$INFRAMAP_IMAGE"
    pull_image "$GRAPHVIZ_IMAGE"

    DOT_FILE="${LAYER_OUTPUT}/${LAYER}.dot"
    PNG_FILE="${LAYER_OUTPUT}/${LAYER}.png"
    SVG_FILE="${LAYER_OUTPUT}/${LAYER}.svg"

    info "Generating DOT graph via inframap..."
    docker run --rm \
      -v "/tmp:/tmp" \
      "$INFRAMAP_IMAGE" \
      generate \
        --tfstate "/tmp/tfstate-${LAYER}-${ENVIRONMENT}.json" \
        --clean=false \
      > "$DOT_FILE" 2>/dev/null \
      || { warn "inframap failed for ${LAYER} — skipping static diagram."; continue; }

    info "Rendering PNG..."
    docker run --rm \
      -v "$(pwd)/${LAYER_OUTPUT}:/out" \
      "$GRAPHVIZ_IMAGE" \
      -Tpng "/out/${LAYER}.dot" -o "/out/${LAYER}.png"

    info "Rendering SVG..."
    docker run --rm \
      -v "$(pwd)/${LAYER_OUTPUT}:/out" \
      "$GRAPHVIZ_IMAGE" \
      -Tsvg "/out/${LAYER}.dot" -o "/out/${LAYER}.svg"

    success "Static diagram → ${PNG_FILE}"
    success "SVG diagram   → ${SVG_FILE}"
    GENERATED+=("${PNG_FILE}" "${SVG_FILE}")
  fi

  # ── interactive HTML via Rover ──────────────────────────────────────────
  if [[ "$FORMAT" == "all" || "$FORMAT" == "html" ]]; then
    ROVER_OUTPUT="${LAYER_OUTPUT}/rover"
    mkdir -p "$ROVER_OUTPUT"

    pull_image "$ROVER_IMAGE"

    info "Generating Rover interactive report..."
    # Rover needs the Terraform working directory with provider plugins,
    # so we generate from the state file via the -tfPath flag pointing to
    # the local state JSON.  If the Terraform directory exists locally we
    # prefer that; otherwise fall back to state-only mode.
    TF_DIR="$(dirname "$0")/${LAYER}/terraform/aws"

    if [[ -d "$TF_DIR/.terraform" ]]; then
      info "Using local Terraform dir: ${TF_DIR}"
      docker run --rm \
        -p 9000:9000 \
        -v "${TF_DIR}:/src" \
        -v "$(pwd)/${ROVER_OUTPUT}:/rover" \
        "$ROVER_IMAGE" \
        -workingDir /src \
        -tfPath /src \
        -standalone true \
        -outputPath /rover \
        2>/dev/null \
        || warn "Rover requires a planned/applied Terraform directory — skipping HTML report."
    else
      warn "Rover HTML skipped for '${LAYER}': local .terraform dir not found."
      warn "Run 'terraform init' in ${LAYER}/terraform/aws first, then re-run this script."
    fi

    GENERATED+=("${ROVER_OUTPUT}/")
  fi

  rm -f "$LOCAL_STATE_FILE"
done

# ── summary ───────────────────────────────────────────────────────────────────
echo
echo "════════════════════════════════════════════════════════"
if [[ ${#GENERATED[@]} -eq 0 ]]; then
  warn "No diagrams generated. Check that apply has run for at least one layer."
else
  success "Generated ${#GENERATED[@]} output(s) in ${OUTPUT_DIR}/"
  for f in "${GENERATED[@]}"; do
    echo "    ${f}"
  done
fi
echo "════════════════════════════════════════════════════════"
echo
info "Open PNG/SVG in any image viewer."
info "Open rover/index.html in a browser for the interactive diagram."
