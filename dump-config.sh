#!/bin/bash
# Pull the live Apollo config from the gaming instance into config/live/ and diff it
# against the canonical copies in config/. Use after experimenting in the Apollo web UI:
#   ./dump-config.sh          # shows drift
#   cp config/live/<file> config/<file> && git diff   # adopt the change, then commit
set -euo pipefail

STACK_NAME="${STACK_NAME:-apollo-gaming}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}"
REGION="${REGION:-eu-central-1}"
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIVE_DIR="$BASE_DIR/config/live"
mkdir -p "$LIVE_DIR"

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

# fetch <remote-windows-path> <local-filename>
# One SSM command per file, base64-encoded to survive SSM output handling.
fetch() {
  local remote_path="$1" local_name="$2"
  local cmd_id
  cmd_id="$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunPowerShellScript \
    --comment "dump-config.sh: read $local_name" \
    --parameters "commands=[\"[Convert]::ToBase64String([IO.File]::ReadAllBytes('$remote_path'))\"]" \
    --region "$REGION" \
    --query 'Command.CommandId' --output text)"
  aws ssm wait command-executed --command-id "$cmd_id" --instance-id "$INSTANCE_ID" \
    --region "$REGION" 2>/dev/null || true
  aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$INSTANCE_ID" \
    --region "$REGION" \
    --query 'StandardOutputContent' --output text | tr -d '[:space:]' | base64 -d > "$LIVE_DIR/$local_name"
  echo "fetched $local_name"
}

ensure_credentials
INSTANCE_ID="$(get_instance_id)"

STATE="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].State.Name' --output text)"
if [[ "$STATE" != "running" ]]; then
  echo "Instance is '$STATE' — start it first (./start-gaming.sh)." >&2
  exit 1
fi

fetch 'C:\Program Files\Apollo\config\apps.json' apps.json
fetch 'C:\Program Files\Apollo\config\sunshine.conf' sunshine.conf

echo
echo "=== Drift vs canonical config/ (no output = no drift) ==="
DRIFT=0
for f in apps.json sunshine.conf; do
  if ! diff -u "$BASE_DIR/config/$f" "$LIVE_DIR/$f"; then
    DRIFT=1
  fi
done
if [[ "$DRIFT" == "0" ]]; then
  echo "No drift — live config matches the repo."
else
  echo
  echo "Drift detected. To adopt live changes: cp config/live/<file> config/<file>, review, commit."
  echo "To discard live changes: ./apply-config.sh"
fi
