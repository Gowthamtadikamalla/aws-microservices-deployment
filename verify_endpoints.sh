#!/usr/bin/env bash
# verify_endpoints.sh
# Tests all service endpoints through the ALB and optionally directly on EC2 instances.
#
# Usage:
#   ALB_DNS=<alb-dns-name> ./verify_endpoints.sh
#   ALB_DNS=<alb-dns-name> INSTANCE1_IP=<ip> INSTANCE2_IP=<ip> ./verify_endpoints.sh
#
# Environment variables:
#   ALB_DNS       (required) - DNS name of the Application Load Balancer
#   AWS_REGION    (optional) - AWS region, default: ap-south-1
#   INSTANCE1_IP  (optional) - Public IP of EC2 instance 1 for direct checks
#   INSTANCE2_IP  (optional) - Public IP of EC2 instance 2 for direct checks
#
# Exit codes:
#   0 - All checks passed
#   1 - One or more checks failed

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
ALB_DNS="${ALB_DNS:-}"
INSTANCE1_IP="${INSTANCE1_IP:-}"
INSTANCE2_IP="${INSTANCE2_IP:-}"
AWS_REGION="${AWS_REGION:-ap-south-1}"
TIMEOUT=15
PASS=0
FAIL=0

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ─── Helpers ──────────────────────────────────────────────────────────────────
pass()  { echo -e "${GREEN}[PASS]${NC} $1"; PASS=$((PASS + 1)); }
fail()  { echo -e "${RED}[FAIL]${NC} $1"; FAIL=$((FAIL + 1)); }
info()  { echo -e "${YELLOW}[INFO]${NC} $1"; }
title() { echo -e "\n${BLUE}--- $1 ---${NC}"; }

check_http() {
    local label="$1"
    local url="$2"
    local expected_code="${3:-200}"
    local expected_body="${4:-}"

    local http_code
    local response_body

    http_code=$(curl -s -o /tmp/verify_body.txt -w "%{http_code}" \
        --max-time "$TIMEOUT" \
        --connect-timeout 5 \
        "$url" 2>/dev/null) || {
        fail "$label — curl failed (connection refused or timeout) | URL: $url"
        return
    }

    response_body=$(cat /tmp/verify_body.txt 2>/dev/null || echo "")

    if [[ "$http_code" != "$expected_code" ]]; then
        fail "$label — Expected HTTP $expected_code, got HTTP $http_code | URL: $url"
        return
    fi

    if [[ -n "$expected_body" ]] && ! echo "$response_body" | grep -q "$expected_body"; then
        fail "$label — Body missing '$expected_body' | Got: $(echo "$response_body" | head -c 150)"
        return
    fi

    pass "$label — HTTP $http_code | $(echo "$response_body" | head -c 100)"
}

check_ecr_repo() {
    local repo_name="$1"
    local uri
    local image_count

    uri=$(aws ecr describe-repositories \
        --repository-names "$repo_name" \
        --region "$AWS_REGION" \
        --query 'repositories[0].repositoryUri' \
        --output text 2>/dev/null) || {
        fail "ECR repo '$repo_name' not found in region $AWS_REGION"
        return
    }

    image_count=$(aws ecr list-images \
        --repository-name "$repo_name" \
        --region "$AWS_REGION" \
        --query 'length(imageIds)' \
        --output text 2>/dev/null) || image_count=0

    if [[ "$image_count" -gt 0 ]]; then
        pass "ECR '$repo_name' — exists at $uri ($image_count image(s) pushed)"
    else
        fail "ECR '$repo_name' — repo exists but no images found at $uri"
    fi
}

# ─── Prerequisites Check ──────────────────────────────────────────────────────
echo ""
echo "============================================="
echo "   Microservices Endpoint Verification"
echo "============================================="
echo ""

if [[ -z "$ALB_DNS" ]]; then
    echo -e "${RED}ERROR: ALB_DNS environment variable is required.${NC}"
    echo "Usage: ALB_DNS=<alb-dns-name> ./verify_endpoints.sh"
    exit 1
fi

echo "ALB DNS    : $ALB_DNS"
echo "AWS Region : $AWS_REGION"
[[ -n "$INSTANCE1_IP" ]] && echo "Instance 1 : $INSTANCE1_IP"
[[ -n "$INSTANCE2_IP" ]] && echo "Instance 2 : $INSTANCE2_IP"

# ─── Stage 1: ECR Validation ──────────────────────────────────────────────────
title "Stage 1: ECR Repository Validation"

if command -v aws &>/dev/null; then
    check_ecr_repo "service1"
    check_ecr_repo "service2"
else
    info "AWS CLI not found — skipping ECR checks"
fi

# ─── Stage 2: ALB Path-Based Routing ─────────────────────────────────────────
title "Stage 2: ALB Path-Based Routing"

check_http "ALB /service1 → service1" \
    "http://${ALB_DNS}/service1" \
    200 \
    "Hello from Service 1"

check_http "ALB /service2 → service2" \
    "http://${ALB_DNS}/service2" \
    200 \
    "Hello from Service 2"

# ─── Stage 3: JSON Response Validation ────────────────────────────────────────
title "Stage 3: JSON Response Shape Validation"

check_http "ALB /service1 returns 'message' field" \
    "http://${ALB_DNS}/service1" \
    200 \
    '"message"'

check_http "ALB /service2 returns 'message' field" \
    "http://${ALB_DNS}/service2" \
    200 \
    '"message"'

# ─── Stage 4: Direct Instance Health Checks ───────────────────────────────────
title "Stage 4: Direct Instance Health Checks"

if [[ -n "$INSTANCE1_IP" ]]; then
    check_http "Instance1 service1 /health (port 5000)" \
        "http://${INSTANCE1_IP}:5000/health" 200 "healthy"
    check_http "Instance1 service2 /health (port 5001)" \
        "http://${INSTANCE1_IP}:5001/health" 200 "healthy"
else
    info "INSTANCE1_IP not set — skipping direct instance 1 health checks"
fi

if [[ -n "$INSTANCE2_IP" ]]; then
    check_http "Instance2 service1 /health (port 5000)" \
        "http://${INSTANCE2_IP}:5000/health" 200 "healthy"
    check_http "Instance2 service2 /health (port 5001)" \
        "http://${INSTANCE2_IP}:5001/health" 200 "healthy"
else
    info "INSTANCE2_IP not set — skipping direct instance 2 health checks"
fi

# ─── Stage 5: Prometheus Metrics Endpoints ────────────────────────────────────
title "Stage 5: Prometheus Metrics Endpoints (direct instance)"

if [[ -n "$INSTANCE1_IP" ]]; then
    check_http "Instance1 service1 /metrics (port 5000)" \
        "http://${INSTANCE1_IP}:5000/metrics" 200 "flask_http"
    check_http "Instance1 service2 /metrics (port 5001)" \
        "http://${INSTANCE1_IP}:5001/metrics" 200 "flask_http"
else
    info "INSTANCE1_IP not set — skipping /metrics checks"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
rm -f /tmp/verify_body.txt

echo ""
echo "============================================="
printf "   Results: "
if [[ "$FAIL" -gt 0 ]]; then
    echo -e "${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
else
    echo -e "${GREEN}${PASS} passed${NC}, ${FAIL} failed"
fi
echo "============================================="

if [[ "$FAIL" -gt 0 ]]; then
    echo -e "${RED}VERIFICATION FAILED${NC}"
    exit 1
else
    echo -e "${GREEN}ALL CHECKS PASSED${NC}"
    exit 0
fi
