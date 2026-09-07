#!/bin/bash
# Install + configure CloudWatch monitoring on the gaming instance via SSM:
#   1. CloudWatch agent (RAM / disk / CPU — see monitoring/cloudwatch-agent.json)
#   2. Custom GPU metrics scheduled task (monitoring/gpu-metrics.ps1, every minute)
# Idempotent — safe to rerun. Requires CloudWatchAgentServerPolicy on the instance role
# (included in apollo-gaming.yaml).
set -euo pipefail

STACK_NAME="${STACK_NAME:-apollo-gaming}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}"
REGION="${REGION:-eu-central-1}"
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

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

run_ssm() { # run_ssm <document> <params-file-or-inline> <comment>
  local doc="$1" params="$2" comment="$3" cmd_id
  cmd_id="$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "$doc" \
    --comment "$comment" \
    --parameters "$params" \
    --region "$REGION" \
    --query 'Command.CommandId' --output text)"
  aws ssm wait command-executed --command-id "$cmd_id" --instance-id "$INSTANCE_ID" \
    --region "$REGION" 2>/dev/null || true
  aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$INSTANCE_ID" \
    --region "$REGION" \
    --query '[Status,StandardOutputContent,StandardErrorContent]' --output text
}

ensure_credentials
INSTANCE_ID="$(get_instance_id)"
echo "Target: $INSTANCE_ID (stack $STACK_NAME)"

echo "== 1/4 Installing CloudWatch agent (Distributor package)..."
run_ssm "AWS-ConfigureAWSPackage" \
  '{"action":["Install"],"name":["AmazonCloudWatchAgent"]}' \
  "setup-monitoring: install CW agent" | head -2

echo "== 2/4 Pushing agent config + GPU metrics script..."
AGENT_B64="$(base64 < "$BASE_DIR/monitoring/cloudwatch-agent.json" | tr -d '\n')"
GPU_B64="$(base64 < "$BASE_DIR/monitoring/gpu-metrics.ps1" | tr -d '\n')"
PARAMS_FILE="$(mktemp)"
trap 'rm -f "$PARAMS_FILE"' EXIT
python3 - "$AGENT_B64" "$GPU_B64" > "$PARAMS_FILE" <<'PYEOF'
import json, sys
agent_b64, gpu_b64 = sys.argv[1], sys.argv[2]
commands = [
    'New-Item -ItemType Directory -Force -Path "C:\\Tools" | Out-Null',
    f'[IO.File]::WriteAllBytes("C:\\ProgramData\\Amazon\\AmazonCloudWatchAgent\\amazon-cloudwatch-agent.json",[Convert]::FromBase64String("{agent_b64}"))',
    f'[IO.File]::WriteAllBytes("C:\\Tools\\gpu-metrics.ps1",[Convert]::FromBase64String("{gpu_b64}"))',
]
print(json.dumps({"commands": commands}))
PYEOF
run_ssm "AWS-RunPowerShellScript" "file://$PARAMS_FILE" "setup-monitoring: push configs" | head -2

echo "== 3/4 Starting CloudWatch agent with the pushed config file..."
run_ssm "AWS-RunPowerShellScript" \
  '{"commands":["& \"C:\\Program Files\\Amazon\\AmazonCloudWatchAgent\\amazon-cloudwatch-agent-ctl.ps1\" -a fetch-config -m ec2 -c file:\"C:\\ProgramData\\Amazon\\AmazonCloudWatchAgent\\amazon-cloudwatch-agent.json\" -s"]}' \
  "setup-monitoring: start CW agent with file config" | head -3

echo "== 4/4 Registering GPU metrics scheduled task (every 1 min)..."
run_ssm "AWS-RunPowerShellScript" \
  '{"commands":["$a=New-ScheduledTaskAction -Execute powershell.exe -Argument \"-NoProfile -ExecutionPolicy Bypass -File C:\\Tools\\gpu-metrics.ps1\"","$t=New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)","Register-ScheduledTask -TaskName GpuMetricsToCloudWatch -Action $a -Trigger $t -User SYSTEM -RunLevel Highest -Force | Out-Null","Start-ScheduledTask -TaskName GpuMetricsToCloudWatch","Write-Output registered"]}' \
  "setup-monitoring: GPU metrics task" | head -3

echo "Done. Metrics appear in CloudWatch namespace CWAgent within ~2 minutes."
