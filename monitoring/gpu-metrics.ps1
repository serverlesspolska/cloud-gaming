# Publishes NVIDIA GPU metrics to CloudWatch every run (scheduled task fires it each minute).
# Windows counterpart of the CloudWatch agent's Linux-only nvidia_gpu plugin: metric names and
# dimensions (InstanceId + index) deliberately mimic the agent's, in the CWAgent namespace, so
# Compute Optimizer can pick them up for GPU rightsizing analysis.
$ErrorActionPreference = "Stop"
Import-Module AWSPowerShell   # must load before Amazon.CloudWatch.Model types are referenced

$smi = "C:\Windows\System32\nvidia-smi.exe"
$fields = "utilization.gpu,utilization.memory,memory.used,memory.total,temperature.gpu,power.draw,clocks.sm,encoder.stats.sessionCount,encoder.stats.averageFps,encoder.stats.averageLatency"
$row = (& $smi --query-gpu=$fields --format=csv,noheader,nounits).Split(",").Trim()

$names = @(
  "nvidia_smi_utilization_gpu",
  "nvidia_smi_utilization_memory",
  "nvidia_smi_memory_used",
  "nvidia_smi_memory_total",
  "nvidia_smi_temperature_gpu",
  "nvidia_smi_power_draw",
  "nvidia_smi_clocks_current_sm",
  "nvidia_smi_encoder_stats_session_count",
  "nvidia_smi_encoder_stats_average_fps",
  "nvidia_smi_encoder_stats_average_latency"
)

# IMDSv2
$token = Invoke-RestMethod -Method PUT -Uri "http://169.254.169.254/latest/api/token" `
  -Headers @{"X-aws-ec2-metadata-token-ttl-seconds" = "300"}
$meta = @{"X-aws-ec2-metadata-token" = $token}
$instanceId = Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/instance-id" -Headers $meta
$region = (Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/placement/region" -Headers $meta)

$dims = @(
  (New-Object Amazon.CloudWatch.Model.Dimension -Property @{Name = "InstanceId"; Value = $instanceId}),
  (New-Object Amazon.CloudWatch.Model.Dimension -Property @{Name = "index"; Value = "0"})
)

$data = @()
for ($i = 0; $i -lt $names.Count; $i++) {
  $v = 0.0
  if (-not [double]::TryParse($row[$i], [ref]$v)) { continue }  # "[N/A]" fields are skipped
  $d = New-Object Amazon.CloudWatch.Model.MetricDatum
  $d.MetricName = $names[$i]
  $d.Value = $v
  $d.Dimensions = $dims
  $data += $d
}

Write-CWMetricData -Namespace "CWAgent" -MetricData $data -Region $region
