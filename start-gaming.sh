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

if [[ "$STATE" == "running" ]]; then
  echo "Instance is already running."
elif [[ "$STATE" == "pending" ]]; then
  echo "Instance is already starting — waiting..."
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
  echo "Instance is running."
elif [[ "$STATE" == "stopping" ]]; then
  echo "Instance is still stopping — waiting for it to stop first..."
  aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID" --region "$REGION"
  echo "Starting instance..."
  aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
  echo "Instance is running."
elif [[ "$STATE" == "stopped" ]]; then
  echo "Starting instance..."
  aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
  echo "Waiting for instance to be running..."
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
  echo "Instance is running."
else
  echo "Instance is in unexpected state '$STATE' — cannot start." >&2
  exit 1
fi

echo ""
echo "Connection info:"
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`ElasticIP`||OutputKey==`ApolloWebUI`].[OutputKey,OutputValue]' \
  --output table
