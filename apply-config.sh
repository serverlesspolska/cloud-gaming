#!/bin/bash
# Push the canonical Apollo config (config/apps.json + config/sunshine.conf) to the
# gaming instance via SSM and restart ApolloService so it takes effect.
#
# WARNING: the restart drops any active Moonlight session.
set -euo pipefail

STACK_NAME="${STACK_NAME:-apollo-gaming}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}"
REGION="${REGION:-eu-central-1}"
CONFIG_DIR="$(cd "$(dirname "$0")" && pwd)/config"

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
INSTANCE_ID="$(get_instance_id)"

STATE="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].State.Name' --output text)"
if [[ "$STATE" != "running" ]]; then
  echo "Instance is '$STATE' — start it first (./start-gaming.sh)." >&2
  exit 1
fi

echo "This will overwrite apps.json + sunshine.conf on $INSTANCE_ID and RESTART Apollo,"
echo "dropping any active stream session."
read -r -p "Continue? [y/N] " REPLY
[[ "$REPLY" == "y" || "$REPLY" == "Y" ]] || exit 1

APPS_B64="$(base64 < "$CONFIG_DIR/apps.json" | tr -d '\n')"
# SUNSHINE_NAME overrides the advertised Moonlight host name for non-main stacks,
# e.g.: SUNSHINE_NAME=Plotka-Test STACK_NAME=apollo-gaming-test ./apply-config.sh
if [[ -n "${SUNSHINE_NAME:-}" ]]; then
  CONF_B64="$(sed "s/^sunshine_name = .*/sunshine_name = ${SUNSHINE_NAME}/" "$CONFIG_DIR/sunshine.conf" | base64 | tr -d '\n')"
else
  CONF_B64="$(base64 < "$CONFIG_DIR/sunshine.conf" | tr -d '\n')"
fi

PARAMS_FILE="$(mktemp)"
trap 'rm -f "$PARAMS_FILE"' EXIT
python3 - "$APPS_B64" "$CONF_B64" > "$PARAMS_FILE" <<'PYEOF'
import json, sys
apps_b64, conf_b64 = sys.argv[1], sys.argv[2]
commands = [
    f'[IO.File]::WriteAllBytes("C:\\Program Files\\Apollo\\config\\apps.json",[Convert]::FromBase64String("{apps_b64}"))',
    f'[IO.File]::WriteAllBytes("C:\\Program Files\\Apollo\\config\\sunshine.conf",[Convert]::FromBase64String("{conf_b64}"))',
    'Restart-Service ApolloService',
    'Start-Sleep -Seconds 5',
    '(Get-Service ApolloService).Status',
]
print(json.dumps({"commands": commands}))
PYEOF

CMD_ID="$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunPowerShellScript \
  --comment "apply-config.sh: push canonical Apollo config" \
  --parameters "file://$PARAMS_FILE" \
  --region "$REGION" \
  --query 'Command.CommandId' --output text)"

aws ssm wait command-executed --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --region "$REGION" 2>/dev/null || true

aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --region "$REGION" \
  --query '[Status,StandardOutputContent,StandardErrorContent]' --output text
echo "Done. Reconnect your Moonlight client."
