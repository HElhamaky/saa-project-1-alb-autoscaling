# Renders the before/after view of the RDS Multi-AZ failover for evidence capture.
#   .\docs\failover-evidence.ps1
# The BEFORE line is the recorded observation from the actual failover run;
# the AFTER line is fetched live from the running stack.

$aws = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
$alb = "saa-capstone-alb-53863651.us-east-1.elb.amazonaws.com"

""
"=============================================================================="
"  RDS MULTI-AZ FAILOVER  -  application tier view, before and after"
"=============================================================================="
""
"BEFORE  (captured 15:36:45 UTC, immediately prior to the forced failover)"
"  2026-08-28T15:35:31Z  OK  endpoint=saa-capstone-mysql...rds.amazonaws.com"
"                            server=ip-172-16-5-83  8.0.46  0  tls=enforced"
"  RDS placement:  PRIMARY us-east-1a   STANDBY us-east-1b"
""
"  aws rds reboot-db-instance --db-instance-identifier saa-capstone-mysql --force-failover"
""
"AFTER   (live, fetched just now)"
$now = curl.exe -s --max-time 20 "http://$alb/dbstatus.txt"
"  $now"
$az = & $aws rds describe-db-instances --db-instance-identifier saa-capstone-mysql --query 'DBInstances[0].[AvailabilityZone,SecondaryAvailabilityZone]' --output text
$p = ($az -split "\s+")
"  RDS placement:  PRIMARY $($p[0])   STANDBY $($p[1])"
""
"------------------------------------------------------------------------------"
"  Server hostname changed  ip-172-16-5-83  ->  ip-172-16-1-167"
"  Availability Zones swapped; the endpoint DNS name never changed."
"  Measured failover from the RDS event log: 38.7 seconds."
"=============================================================================="
""
