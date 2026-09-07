# Renders the before/after view of an RDS Multi-AZ failover for evidence capture.
#
#   .\docs\failover-evidence.ps1 -Before    # run FIRST, saves the baseline
#   aws rds reboot-db-instance --db-instance-identifier saa-capstone-mysql --force-failover
#   .\docs\failover-evidence.ps1            # run AFTER, prints before vs after
#
# The baseline is unrecoverable once the failover has happened, so -Before must
# be run first. Endpoints are read from Terraform output, so this stays correct
# across redeployments.

param([switch]$Before)

$aws       = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
$repoRoot  = Split-Path $PSScriptRoot -Parent
$baseline  = Join-Path $PSScriptRoot ".failover-baseline.txt"

Push-Location (Join-Path $repoRoot "terraform")
$alb = (terraform output -raw alb_dns_name)
Pop-Location

function Get-DbLine  { curl.exe -s --max-time 20 "http://$alb/dbstatus.txt" }
function Get-Placement {
  $az = & $aws rds describe-db-instances --db-instance-identifier saa-capstone-mysql `
        --query 'DBInstances[0].[AvailabilityZone,SecondaryAvailabilityZone]' --output text
  $p = $az -split "\s+"
  "PRIMARY $($p[0])   STANDBY $($p[1])"
}

if ($Before) {
  $stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  @("captured $stamp", (Get-DbLine), (Get-Placement)) | Set-Content -Path $baseline -Encoding utf8
  ""
  "Baseline saved. Now trigger the failover:"
  ""
  "  aws rds reboot-db-instance --db-instance-identifier saa-capstone-mysql --force-failover"
  ""
  "Then wait ~3 minutes for the probe timer and run this script with no arguments."
  ""
  exit
}

if (-not (Test-Path $baseline)) {
  "No baseline found. Run '.\docs\failover-evidence.ps1 -Before' BEFORE triggering the failover."
  exit 1
}

$b = Get-Content $baseline

""
"=============================================================================="
"  RDS MULTI-AZ FAILOVER  -  application tier view, before and after"
"=============================================================================="
""
"BEFORE  ($($b[0]))"
"  $($b[1])"
"  RDS placement:  $($b[2])"
""
"  aws rds reboot-db-instance --db-instance-identifier saa-capstone-mysql --force-failover"
""
"AFTER   (live, fetched just now)"
"  $(Get-DbLine)"
"  RDS placement:  $(Get-Placement)"
""
"------------------------------------------------------------------------------"
"  A changed server= hostname means the standby was promoted."
"  The endpoint DNS name never changes, so the application needs no edit."
"  Measure the true duration from: aws rds describe-events --duration 60"
"=============================================================================="
""
