#!/usr/bin/env bash
# Full initial deployment: CloudFormation → ACM cert (manual Cloudflare DNS) → S3 sync → CloudFront
# Usage: ./scripts/deploy.sh [stack-name] [region] [aws-profile]
set -euo pipefail

STACK_NAME="${1:-msmith-website}"
REGION="${2:-us-east-1}"
AWS_PROFILE="${3:-gcs}"

AWS="aws --region $REGION --profile $AWS_PROFILE"
BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'

log()    { echo -e "${CYAN}[deploy]${NC} $*"; }
ok()     { echo -e "${GREEN}[✓]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
err()    { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
bold()   { echo -e "${BOLD}$*${NC}"; }
divider(){ echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"; }

# ─── Prerequisites ────────────────────────────────────────────────────────────

for cmd in aws jq; do
  command -v "$cmd" &>/dev/null || err "Required tool not found: $cmd"
done

[[ "$REGION" == "us-east-1" ]] || \
  err "CloudFront ACM certificates must be in us-east-1. Re-run: ./scripts/deploy.sh $STACK_NAME us-east-1 $AWS_PROFILE"

# ─── Step 1: Deploy CloudFormation in background ─────────────────────────────
# The stack will pause at the Certificate resource until DNS validation CNAMEs
# are added to Cloudflare. We surface those records while it waits.

log "Step 1/3 — Submitting CloudFormation stack: $STACK_NAME"

$AWS cloudformation deploy \
  --template-file "$(dirname "$0")/../cloudformation.yaml" \
  --stack-name "$STACK_NAME" \
  --no-fail-on-empty-changeset \
  --output text &
DEPLOY_PID=$!

# ─── Step 2: Surface ACM validation CNAMEs ───────────────────────────────────
# Poll until CloudFormation creates the certificate, then extract and print
# the DNS validation records so you can add them to Cloudflare.

log "Waiting for ACM certificate to be requested..."
CERT_SHOWN=false

while kill -0 $DEPLOY_PID 2>/dev/null; do
  if [[ "$CERT_SHOWN" == "false" ]]; then
    CERT_ARN=$($AWS cloudformation describe-stack-resource \
      --stack-name "$STACK_NAME" \
      --logical-resource-id "Certificate" \
      --query "StackResourceDetail.PhysicalResourceId" \
      --output text 2>/dev/null || true)

    if [[ -n "$CERT_ARN" && "$CERT_ARN" != "None" ]]; then
      # Wait for validation options to populate (takes a few seconds after cert creation)
      RECORDS=$($AWS acm describe-certificate \
        --certificate-arn "$CERT_ARN" \
        --region us-east-1 \
        --query "Certificate.DomainValidationOptions[?ResourceRecord!=null].ResourceRecord" \
        --output json 2>/dev/null || echo "[]")

      if [[ "$RECORDS" != "[]" && "$RECORDS" != "null" && "$(echo "$RECORDS" | jq 'length')" -gt 0 ]]; then
        CERT_SHOWN=true

        # Deduplicate by Name (ACM often reuses the same CNAME for apex + www)
        UNIQUE_RECORDS=$(echo "$RECORDS" | jq '[group_by(.Name)[] | first]')

        echo ""
        divider
        warn " ACTION REQUIRED — Add these CNAME records to Cloudflare DNS"
        divider
        echo ""
        echo "  In Cloudflare: DNS → Add record → Type: CNAME"
        echo "  Set each record to  Proxy status: DNS only  (grey cloud)"
        echo ""
        echo "$UNIQUE_RECORDS" | jq -r '.[] |
          "  ┌ Name (strip your domain suffix when entering in Cloudflare)\n" +
          "  │ \(.Name)\n" +
          "  └ Value\n" +
          "    \(.Value)\n"'
        echo "  CloudFormation will complete automatically once Cloudflare propagates."
        echo "  This typically takes 1–5 minutes."
        divider
        echo ""
      fi
    fi
  fi
  sleep 5
done

# Capture exit code of the background deploy
wait $DEPLOY_PID || err "CloudFormation deployment failed. Check the AWS console for details."
ok "CloudFormation stack deployed"

# ─── Step 3: Sync + invalidate ────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

BUCKET=$($AWS cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" \
  --output text)
DIST_ID=$($AWS cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='DistributionId'].OutputValue" \
  --output text)
CF_DOMAIN=$($AWS cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='DistributionDomain'].OutputValue" \
  --output text)
WEBSITE_URL=$($AWS cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='WebsiteURL'].OutputValue" \
  --output text)

log "Step 2/3 — Syncing static files to S3: $BUCKET"

# Static assets (css/js/images/pdf) — cache for a day; CloudFront invalidation
# on every deploy means updates still show up immediately.
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

# index.html — never cache, so edits are picked up without waiting on TTL.
$AWS s3 cp "$REPO_ROOT/index.html" "s3://$BUCKET/index.html" \
  --cache-control "public,max-age=0,must-revalidate"

ok "Synced to s3://$BUCKET"

log "Step 3/3 — Invalidating CloudFront cache"
$AWS cloudfront create-invalidation \
  --distribution-id "$DIST_ID" \
  --paths "/*" \
  --output text > /dev/null
ok "Cache invalidated"

# ─── Done ─────────────────────────────────────────────────────────────────────

echo ""
divider
bold " msmith.org deployed successfully!"
divider
echo ""
echo "  Website:    $WEBSITE_URL"
echo "  CloudFront: https://$CF_DOMAIN"
echo ""
bold " Final Cloudflare DNS records to add:"
echo ""
echo "  Type  Name   Value                  Proxy"
echo "  CNAME @      $CF_DOMAIN   DNS only"
echo "  CNAME www    $CF_DOMAIN   DNS only"
echo ""
echo "  (Use Cloudflare's CNAME flattening for the apex @ record)"
echo ""
echo "  To redeploy after content changes:"
echo "    ./scripts/update.sh $STACK_NAME $REGION $AWS_PROFILE"
echo ""
