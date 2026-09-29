#!/usr/bin/env bash
# Quick redeploy after content changes: S3 sync → CloudFront invalidation
# Usage: ./scripts/update.sh [stack-name] [region] [aws-profile]
set -euo pipefail

STACK_NAME="${1:-msmith-website}"
REGION="${2:-us-east-1}"
AWS_PROFILE="${3:-gcs}"

AWS="aws --region $REGION --profile $AWS_PROFILE"
CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${CYAN}[update]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
bold() { echo -e "${BOLD}$*${NC}"; }

command -v aws &>/dev/null || err "Required tool not found: aws"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ─── Get stack outputs ────────────────────────────────────────────────────────

log "Fetching stack outputs: $STACK_NAME"

BUCKET=$($AWS cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" \
  --output text)
DIST_ID=$($AWS cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='DistributionId'].OutputValue" \
  --output text)
WEBSITE_URL=$($AWS cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='WebsiteURL'].OutputValue" \
  --output text)

[[ -n "$BUCKET" ]]  || err "BucketName not found. Has $STACK_NAME been deployed?"
[[ -n "$DIST_ID" ]] || err "DistributionId not found."
ok "Bucket: $BUCKET | Distribution: $DIST_ID"

# ─── Sync ─────────────────────────────────────────────────────────────────────

log "Step 1/2 — Syncing static files to S3"

$AWS s3 sync "$REPO_ROOT" "s3://$BUCKET" \
  --delete \
  --exclude "*" \
  --include "css/*" \
  --include "js/*" \
  --include "assets/*" \
  --include "robots.txt" \
  --include "sitemap.xml" \
  --include "llms.txt" \
  --cache-control "public,max-age=86400"

$AWS s3 cp "$REPO_ROOT/index.html" "s3://$BUCKET/index.html" \
  --cache-control "public,max-age=0,must-revalidate"

ok "Synced to s3://$BUCKET"

# ─── Invalidate ───────────────────────────────────────────────────────────────

log "Step 2/2 — Invalidating CloudFront cache"
$AWS cloudfront create-invalidation \
  --distribution-id "$DIST_ID" \
  --paths "/*" \
  --output text > /dev/null
ok "Cache invalidated"

echo ""
bold "Update complete! → $WEBSITE_URL"
echo ""
