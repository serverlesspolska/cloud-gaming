#!/bin/bash
set -euo pipefail

STACK_NAME="${STACK_NAME:-apollo-gaming}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}"
REGION="${REGION:-eu-central-1}"

ensure_credentials() {
  if ! aws sts get-caller-identity --region "$REGION" > /dev/null 2>&1; then
    echo "No valid AWS credentials found." >&2
    echo "Configure credentials first: 'aws configure', environment variables, or AWS_PROFILE." >&2
    echo "For SSO profiles run: aws sso login${AWS_PROFILE:+ --profile "$AWS_PROFILE"}" >&2
    exit 1
  fi
}

get_instance_id() {
  aws cloudformation describe-stack-resource \
    --stack-name "$STACK_NAME" \
    --logical-resource-id ec2Instance \
    --region "$REGION" \
    --query 'StackResourceDetail.PhysicalResourceId' \
    --output text
}

ensure_credentials

echo "Fetching instance ID from stack '$STACK_NAME'..."
INSTANCE_ID="$(get_instance_id)"
echo "Instance: $INSTANCE_ID"

STATE="$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text)"

if [[ "$STATE" == "stopped" ]]; then
  echo "Instance is already stopped."
elif [[ "$STATE" == "stopping" ]]; then
  echo "Instance is already stopping — waiting..."
  aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID" --region "$REGION"
  echo "Instance is stopped."
elif [[ "$STATE" == "running" ]]; then
  echo "Stopping instance..."
  aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
  echo "Waiting for instance to stop..."
  aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID" --region "$REGION"
  echo "Instance is stopped."
elif [[ "$STATE" == "pending" ]]; then
  echo "Instance is still starting — waiting for it to be running first..."
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
  echo "Stopping instance..."
  aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
  aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID" --region "$REGION"
  echo "Instance is stopped."
else
  echo "Instance is in unexpected state '$STATE' — cannot stop." >&2
  exit 1
fi
