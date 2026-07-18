#!/usr/bin/env bash
# deploy-ecs-autopilot.sh — build, push, and deploy the Firstmate autopilot to
# ECS Fargate on the existing armalo-admin-swarm cluster.
#
# Mirrors flowstate/scripts/deploy-ecs-flowstate.sh in style: ensure ECR repo,
# build + push the arm64 image, ensure the log group, ensure Secrets Manager
# placeholders exist (created EMPTY — the operator must populate real values),
# attach the execution role's read policy for those secrets, render + register
# the task definition, and create/update the fm-autopilot service (desiredCount 1,
# no load balancer). --dry-run prints the plan without touching AWS.
#
# Run from the firstmate repo root (the docker build context):
#   deploy/deploy-ecs-autopilot.sh            # full deploy
#   deploy/deploy-ecs-autopilot.sh --dry-run  # plan only
set -euo pipefail

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
DEPLOY_DIR="$ROOT/deploy"

REGION="${AWS_REGION:-us-west-2}"
CLUSTER="${FM_AUTOPILOT_ECS_CLUSTER:-armalo-admin-swarm}"
SERVICE="${FM_AUTOPILOT_ECS_SERVICE:-fm-autopilot}"
FAMILY="${FM_AUTOPILOT_ECS_TASK_FAMILY:-fm-autopilot}"
CONTAINER="${FM_AUTOPILOT_ECS_CONTAINER:-fm-autopilot}"
ECR_REPO="${FM_AUTOPILOT_ECR_REPO:-armalo/fm-autopilot}"
LOG_GROUP="${FM_AUTOPILOT_LOG_GROUP:-/ecs/fm-autopilot}"

# Network + roles: match the armalo-engine / flowstate Fargate precedent on this
# cluster. Override via env if the account's values differ.
TASK_SG="${FM_AUTOPILOT_TASK_SECURITY_GROUP:-sg-036114dc851801b3e}"
SUBNETS_CSV="${FM_AUTOPILOT_SUBNETS:-subnet-4d2b472a,subnet-861097cf}"

# Secret names (short); ARNs are resolved/created below.
GH_SECRET_NAME="${FM_AUTOPILOT_GH_SECRET_NAME:-fm/gh-token}"
CLAUDE_SECRET_NAME="${FM_AUTOPILOT_CLAUDE_SECRET_NAME:-fm/claude-credentials}"
CODEX_SECRET_NAME="${FM_AUTOPILOT_CODEX_SECRET_NAME:-fm/codex-auth}"

# What repos the cloud home clones + autopilots. Live-trading repos are omitted
# on purpose; keep them out of the cloud fleet.
FM_PROJECTS_SPEC="${FM_PROJECTS_SPEC:-}"

TASK_CPU="${FM_AUTOPILOT_TASK_CPU:-1024}"
TASK_MEMORY="${FM_AUTOPILOT_TASK_MEMORY:-4096}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }; }
need aws; need jq
[ "$DRY_RUN" = 1 ] || need docker

ACCOUNT_ID="${FM_AUTOPILOT_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo ACCOUNT_ID)}"
EXECUTION_ROLE="${FM_AUTOPILOT_EXECUTION_ROLE:-arn:aws:iam::${ACCOUNT_ID}:role/armalo-engine-ecs-execution}"
TASK_ROLE="${FM_AUTOPILOT_TASK_ROLE:-arn:aws:iam::${ACCOUNT_ID}:role/armalo-engine-task}"

ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}"
IMAGE_TAG="${FM_AUTOPILOT_IMAGE_TAG:-$(git rev-parse --short=12 HEAD 2>/dev/null || echo manual)-$(date -u +%Y%m%d%H%M%S)}"
IMAGE_URI="${ECR_URI}:${IMAGE_TAG}"
LATEST_URI="${ECR_URI}:latest"

echo "=== fm-autopilot ECS deploy ==="
echo "region:    ${REGION}"
echo "account:   ${ACCOUNT_ID}"
echo "cluster:   ${CLUSTER}"
echo "service:   ${SERVICE}"
echo "image:     ${IMAGE_URI}"
echo "exec role: ${EXECUTION_ROLE}"
echo "task role: ${TASK_ROLE}"
echo "projects:  ${FM_PROJECTS_SPEC:-<none set — export FM_PROJECTS_SPEC>}"
echo "dry-run:   ${DRY_RUN}"
echo

run() { # run <description> <cmd...>
  local desc="$1"; shift
  if [ "$DRY_RUN" = 1 ]; then
    printf 'DRY-RUN would %s:\n  %s\n' "$desc" "$*"
  else
    "$@"
  fi
}

secret_arn() { aws secretsmanager describe-secret --region "$REGION" --secret-id "$1" --query ARN --output text 2>/dev/null || true; }

ensure_secret_placeholder() { # ensure_secret_placeholder <name> -> echoes ARN (or placeholder in dry-run)
  local name="$1" arn
  arn="$(secret_arn "$name")"
  if [ -n "$arn" ] && [ "$arn" != "None" ]; then
    echo "$arn"; return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    echo "arn:aws:secretsmanager:${REGION}:${ACCOUNT_ID}:secret:${name}"
    printf 'DRY-RUN would create EMPTY secret placeholder: %s\n' "$name" >&2
    return 0
  fi
  echo ">>> creating EMPTY secret placeholder ${name} — POPULATE IT before autopilot can act (see deploy/README.md)" >&2
  aws secretsmanager create-secret --region "$REGION" --name "$name" \
    --description "fm-autopilot placeholder; populate with real value" \
    --secret-string "PLACEHOLDER_POPULATE_ME" \
    --query ARN --output text
}

# --- Secrets -----------------------------------------------------------------
GH_SECRET_ARN="$(ensure_secret_placeholder "$GH_SECRET_NAME")"
CLAUDE_SECRET_ARN="$(ensure_secret_placeholder "$CLAUDE_SECRET_NAME")"
CODEX_SECRET_ARN="$(ensure_secret_placeholder "$CODEX_SECRET_NAME")"
echo "gh secret:     ${GH_SECRET_ARN}"
echo "claude secret: ${CLAUDE_SECRET_ARN}"
echo "codex secret:  ${CODEX_SECRET_ARN}"

# --- Execution role: allow reading those three secrets -----------------------
SECRETS_POLICY="$(jq -n \
  --arg a "$GH_SECRET_ARN" --arg b "$CLAUDE_SECRET_ARN" --arg c "$CODEX_SECRET_ARN" \
  '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:["secretsmanager:GetSecretValue"],Resource:[$a,$b,$c]}]}')"
run "attach secrets-read policy to $(basename "$EXECUTION_ROLE")" \
  aws iam put-role-policy --role-name "$(basename "$EXECUTION_ROLE")" \
    --policy-name fm-autopilot-secrets-read --policy-document "$SECRETS_POLICY"

# --- ECR repo ----------------------------------------------------------------
if [ "$DRY_RUN" = 1 ]; then
  printf 'DRY-RUN would ensure ECR repo: %s\n' "$ECR_REPO"
else
  aws ecr describe-repositories --region "$REGION" --repository-names "$ECR_REPO" >/dev/null 2>&1 \
    || aws ecr create-repository --region "$REGION" --repository-name "$ECR_REPO" >/dev/null
fi

# --- Build + push image (arm64) ----------------------------------------------
if [ "$DRY_RUN" = 1 ]; then
  printf 'DRY-RUN would build+push: docker build --platform linux/arm64 -f deploy/Dockerfile.autopilot -t %s .\n' "$IMAGE_URI"
else
  aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com" >/dev/null
  docker build --platform linux/arm64 -f deploy/Dockerfile.autopilot -t "$IMAGE_URI" -t "$LATEST_URI" .
  docker push "$IMAGE_URI"
  docker push "$LATEST_URI"
fi

# --- Log group ---------------------------------------------------------------
run "ensure log group $LOG_GROUP" \
  aws logs create-log-group --region "$REGION" --log-group-name "$LOG_GROUP"

# --- Render + register task definition ---------------------------------------
RENDERED="$(mktemp "${TMPDIR:-/tmp}/fm-autopilot-taskdef.XXXXXX.json")"
trap 'rm -f "$RENDERED"' EXIT
sed \
  -e "s#__IMAGE_URI__#${IMAGE_URI}#g" \
  -e "s#__ACCOUNT_ID__#${ACCOUNT_ID}#g" \
  -e "s#__REGION__#${REGION}#g" \
  -e "s#__EXECUTION_ROLE_ARN__#${EXECUTION_ROLE}#g" \
  -e "s#__TASK_ROLE_ARN__#${TASK_ROLE}#g" \
  -e "s#__GH_TOKEN_SECRET_ARN__#${GH_SECRET_ARN}#g" \
  -e "s#__CLAUDE_SECRET_ARN__#${CLAUDE_SECRET_ARN}#g" \
  -e "s#__CODEX_SECRET_ARN__#${CODEX_SECRET_ARN}#g" \
  -e "s#__LOG_GROUP__#${LOG_GROUP}#g" \
  -e "s#__FM_PROJECTS_SPEC__#${FM_PROJECTS_SPEC}#g" \
  "$DEPLOY_DIR/task-def-autopilot.json" > "$RENDERED"

# Reflect CPU/memory overrides if the caller changed them.
tmp="$(mktemp)"; jq --arg c "$TASK_CPU" --arg m "$TASK_MEMORY" '.cpu=$c | .memory=$m' "$RENDERED" > "$tmp" && mv "$tmp" "$RENDERED"

echo "--- rendered task definition ---"
jq . "$RENDERED"

if [ "$DRY_RUN" = 1 ]; then
  printf 'DRY-RUN would register task def family %s and create/update service %s (desiredCount 1)\n' "$FAMILY" "$SERVICE"
  echo "DRY-RUN complete."
  exit 0
fi

TASK_DEF_ARN="$(aws ecs register-task-definition --region "$REGION" \
  --cli-input-json "file://${RENDERED}" \
  --query 'taskDefinition.taskDefinitionArn' --output text)"
echo "registered: ${TASK_DEF_ARN}"

# --- Create / update service (no load balancer) ------------------------------
SERVICE_STATUS="$(aws ecs describe-services --region "$REGION" --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].status' --output text 2>/dev/null || true)"
NETWORK_CONFIG="awsvpcConfiguration={subnets=[${SUBNETS_CSV}],securityGroups=[${TASK_SG}],assignPublicIp=ENABLED}"

if [ "$SERVICE_STATUS" = "ACTIVE" ]; then
  aws ecs update-service --region "$REGION" --cluster "$CLUSTER" --service "$SERVICE" \
    --task-definition "$TASK_DEF_ARN" --desired-count 1 >/dev/null
  echo "service updated: ${SERVICE}"
else
  aws ecs create-service --region "$REGION" --cluster "$CLUSTER" \
    --service-name "$SERVICE" --task-definition "$TASK_DEF_ARN" \
    --desired-count 1 --launch-type FARGATE \
    --network-configuration "$NETWORK_CONFIG" >/dev/null
  echo "service created: ${SERVICE}"
fi

echo "waiting for service to stabilize..."
aws ecs wait services-stable --region "$REGION" --cluster "$CLUSTER" --services "$SERVICE"

echo
echo "ok: fm-autopilot service stable (desiredCount 1)"
echo "taskDefinition: ${TASK_DEF_ARN}"
echo "image:          ${IMAGE_URI}"
echo "logs:           aws logs tail ${LOG_GROUP} --region ${REGION} --follow"

