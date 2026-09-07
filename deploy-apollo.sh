#!/bin/bash
set -euo pipefail

# Deploy (or update) the cloud gaming stack. Every setting is overridable via
# environment variables, e.g.:
#   STACK_NAME=apollo-gaming-test INSTANCE_TYPE=g6.xlarge VOLUME_SIZE=100 ./deploy-apollo.sh
# See .envrc.example for the full list.
STACK_NAME="${STACK_NAME:-apollo-gaming}"
TEMPLATE_FILE="apollo-gaming.yaml"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}"
REGION="${REGION:-eu-central-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g6.2xlarge}"
VOLUME_SIZE="${VOLUME_SIZE:-100}"
AUTO_STOP_TIMEZONE="${AUTO_STOP_TIMEZONE:-UTC}"
# Cost allocation tags: Application groups the project, Purpose separates the
# stacks in Cost Explorer. Activate both tags in the Billing console to use them.
if [ -z "${PURPOSE:-}" ]; then
  if [ "$STACK_NAME" = "apollo-gaming" ]; then PURPOSE="main-rig"; else PURPOSE="test"; fi
fi
# Windows Administrator + Apollo web UI password. Never hardcode it here:
# it comes from .envrc (see .envrc.example) or the prompt below.
if [ -z "${ADMIN_PASSWORD:-}" ]; then
  read -r -s -p "Administrator password: " ADMIN_PASSWORD
  echo
fi

echo "🔐 Checking AWS credentials..."
if ! aws sts get-caller-identity --region "$REGION" > /dev/null 2>&1; then
  echo "No valid AWS credentials found." >&2
  echo "Configure credentials first: 'aws configure', environment variables, or AWS_PROFILE." >&2
  echo "For SSO profiles run: aws sso login${AWS_PROFILE:+ --profile "$AWS_PROFILE"}" >&2
  exit 1
fi

# --- AMI: resolve once, then stay pinned ---
# The script reuses the AMI the stack already runs, so routine redeploys (for example
# a home-IP refresh) never replace the instance. A changed imageId REPLACES the
# instance and deletes its disk, installed games included. To upgrade deliberately:
#   IMAGE_ID=<ami-...> ./deploy-apollo.sh
if [ -n "${IMAGE_ID:-}" ]; then
  echo "🖥  Using AMI from IMAGE_ID: $IMAGE_ID"
else
  IMAGE_ID="$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Parameters[?ParameterKey=='imageId'].ParameterValue | [0]" \
    --output text 2>/dev/null || true)"
  if [ -n "$IMAGE_ID" ] && [ "$IMAGE_ID" != "None" ]; then
    echo "🖥  Reusing the AMI pinned in the stack: $IMAGE_ID"
  else
    IMAGE_ID="$(aws ssm get-parameters \
      --names /aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base \
      --region "$REGION" --query 'Parameters[0].Value' --output text)"
    echo "🖥  Resolved latest Windows Server 2022 AMI: $IMAGE_ID"
  fi
fi

# --- Availability Zone: pick one that offers the instance type ---
if [ -z "${AZ:-}" ]; then
  AZ="$(aws ec2 describe-instance-type-offerings --location-type availability-zone \
    --filters "Name=instance-type,Values=$INSTANCE_TYPE" --region "$REGION" \
    --query 'InstanceTypeOfferings[0].Location' --output text)"
  if [ -z "$AZ" ] || [ "$AZ" = "None" ]; then
    echo "❌ $INSTANCE_TYPE is not offered in $REGION. Pick a different region or instance type." >&2
    exit 1
  fi
fi

MY_IP="$(curl -s https://checkip.amazonaws.com)"

echo "🌍 Using source IP: $MY_IP/32"
echo "📦 Deploying CloudFormation stack: $STACK_NAME ($INSTANCE_TYPE in $AZ)"
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE_FILE" \
  --capabilities CAPABILITY_IAM \
  --region "$REGION" \
  --no-fail-on-empty-changeset \
  --tags \
    "Application=CloudGaming" \
    "Purpose=$PURPOSE" \
  --parameter-overrides \
    "imageId=$IMAGE_ID" \
    "instanceType=$INSTANCE_TYPE" \
    "volumeSize=$VOLUME_SIZE" \
    "availabilityZone=$AZ" \
    "autoStopTimezone=$AUTO_STOP_TIMEZONE" \
    "ingressIPv4=$MY_IP/32" \
    "administratorPassword=$ADMIN_PASSWORD"

echo "✅ Stack deployed. Outputs:"
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs' \
  --output table
