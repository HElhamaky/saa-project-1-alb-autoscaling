# Starts the CPU load generator on every running instance in the Auto Scaling
# Group, so the target-tracking policy fires and the group scales out.
#
#   .\docs\start-burn.ps1              # 25 minutes (default)
#   .\docs\start-burn.ps1 -Seconds 600 # 10 minutes
#
# Instance IDs are resolved at run time rather than hardcoded - scale-in
# terminates instances without warning, and a stale ID fails with
# TargetNotConnected.
#
# The command is delivered as a JSON file rather than an inline argument.
# burn-cpu.sh must be launched with `>/dev/null 2>&1 </dev/null &`, and
# PowerShell parses `<` and `&` as operators, so building that inline is a
# parse error every time.

param([int]$Seconds = 1500)

$aws      = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
$repoRoot = Split-Path $PSScriptRoot -Parent

Push-Location (Join-Path $repoRoot "terraform")
$asg = terraform output -raw asg_name
Pop-Location

$ids = (& $aws ec2 describe-instances `
    --filters "Name=tag:aws:autoscaling:groupName,Values=$asg" "Name=instance-state-name,Values=running" `
    --query 'Reservations[].Instances[].InstanceId' --output text) -split "\s+" | Where-Object { $_ }

if (-not $ids) { "No running instances found in $asg."; exit 1 }

"Instances: $($ids -join ', ')"
"Duration : $Seconds seconds"
"Start    : $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) UTC"
""

$idJson = ($ids | ForEach-Object { '"' + $_ + '"' }) -join ','
$payload = @"
{
  "InstanceIds": [$idJson],
  "DocumentName": "AWS-RunShellScript",
  "TimeoutSeconds": 600,
  "Parameters": {
    "commands": [
      "setsid nohup /usr/local/bin/burn-cpu.sh $Seconds >/dev/null 2>&1 < /dev/null &",
      "sleep 3",
      "echo \"burn processes: \$(pgrep -c -f burn-cpu)\"",
      "uptime"
    ]
  }
}
"@

$tmp = Join-Path $env:TEMP "saa-burn-$(Get-Random).json"
[System.IO.File]::WriteAllText($tmp, $payload, (New-Object System.Text.UTF8Encoding($false)))

$cid = & $aws ssm send-command --cli-input-json "file://$tmp" --query 'Command.CommandId' --output text
"Command id: $cid"

& $aws ssm wait command-executed --command-id $cid --instance-id $ids[0] 2>$null

foreach ($id in $ids) {
  "--- $id ---"
  & $aws ssm get-command-invocation --command-id $cid --instance-id $id --query 'StandardOutputContent' --output text
}

Remove-Item $tmp -Force -ErrorAction SilentlyContinue

""
"Expect 'burn processes: 2' per instance."
"The alarm takes ~3-4 min to fire; the group reaches full capacity ~5-6 min in."
"Next: wait ~1 minute, then trigger the failover so both land in one dashboard frame:"
""
"  aws rds reboot-db-instance --db-instance-identifier saa-capstone-mysql --force-failover --query `"DBInstance.DBInstanceStatus`" --output text"
""
