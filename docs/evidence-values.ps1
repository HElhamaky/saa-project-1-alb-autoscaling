# Prints every endpoint and ID the evidence-capture guide refers to.
# Re-run whenever a command fails on a missing resource - instance IDs in an
# Auto Scaling Group change without warning when the group scales in.
#
#   .\docs\evidence-values.ps1

$aws      = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
$repoRoot = Split-Path $PSScriptRoot -Parent

Push-Location (Join-Path $repoRoot "terraform")
$alb = terraform output -raw alb_dns_name
$asg = terraform output -raw asg_name
$cf  = terraform output -raw cloudfront_url
$dash = terraform output -raw dashboard_url
Pop-Location

$cfHost = $cf -replace '^https?://',''

""
"=============================================================================="
"  EVIDENCE CAPTURE - live values     $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC"
"=============================================================================="
""
"ALB           $alb"
"CloudFront    $cfHost"
"ASG           $asg"
""
"--- instances (fetch fresh, these change on every scale event) ---"
& $aws ec2 describe-instances `
    --filters "Name=tag:aws:autoscaling:groupName,Values=$asg" "Name=instance-state-name,Values=running" `
    --query 'Reservations[].Instances[].[InstanceId,Placement.AvailabilityZone,PrivateIpAddress]' `
    --output text | ForEach-Object { "  $_" }

""
"--- SSM reachability ---"
& $aws ssm describe-instance-information `
    --query 'InstanceInformationList[].[InstanceId,PingStatus]' --output text | ForEach-Object { "  $_" }

""
"--- security groups (screenshot 06) ---"
$rdsSg = & $aws ec2 describe-security-groups --filters "Name=group-name,Values=saa-capstone-rds-sg" --query 'SecurityGroups[0].GroupId' --output text
$appSg = & $aws ec2 describe-security-groups --filters "Name=group-name,Values=saa-capstone-app-sg" --query 'SecurityGroups[0].GroupId' --output text
"  rds-sg  $rdsSg   <- open this one"
"  app-sg  $appSg   <- expected Source in its inbound rule"

""
"--- SNS subscription (screenshot 14 needs this CONFIRMED) ---"
& $aws sns list-subscriptions --query "Subscriptions[?contains(TopicArn,'saa-capstone')].[Endpoint,SubscriptionArn]" --output text | ForEach-Object { "  $_" }

""
"--- console links ---"
"  ASG activity   https://us-east-1.console.aws.amazon.com/ec2/home?region=us-east-1#AutoScalingGroupDetails:id=$asg;view=activity"
"  RDS events     https://us-east-1.console.aws.amazon.com/rds/home?region=us-east-1#database:id=saa-capstone-mysql;is-cluster=false;tab=logs-and-events"
"  RDS sec group  https://us-east-1.console.aws.amazon.com/ec2/home?region=us-east-1#SecurityGroup:groupId=$rdsSg"
"  Secret         https://us-east-1.console.aws.amazon.com/secretsmanager/secret?name=saa-capstone/rds/master-credentials&region=us-east-1"
"  Dashboard      $dash"
""
"--- ready-to-paste ---"
"  aws ssm start-session --target <id from above>"
"  curl.exe -i --max-time 20 `"http://$alb/admin`""
""
