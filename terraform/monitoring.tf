###############################################################################
# Observability: SNS + CloudWatch alarms + a single dashboard.
###############################################################################

###############################################################################
# KMS key for the alerts topic.
#
# WHY A CUSTOMER-MANAGED KEY IS REQUIRED HERE, and not merely preferred:
#
# To publish to an SSE-enabled SNS topic, the PUBLISHER needs kms:Decrypt and
# kms:GenerateDataKey* on the topic's key. The AWS-managed key `alias/aws/sns`
# grants only sns.amazonaws.com, and an AWS-managed key policy CANNOT be
# edited. So a CloudWatch alarm pointed at an aws/sns-encrypted topic fails at
# the KMS step - before SNS ever sees the message.
#
# The failure is silent and easy to misread. The alarm history says only
# "Failed to execute action", and the giveaway is that the topic's
# NumberOfMessagesPublished stays at ZERO - not "published but not delivered".
# Published-vs-delivered is the metric pair that separates "the publisher
# cannot reach the topic" from "the topic has no confirmed subscriber".
#
# This was found the hard way: alarms fired correctly for a full scaling demo
# and no email ever arrived.
###############################################################################

resource "aws_kms_key" "sns" {
  description             = "${local.name} - encrypts the CloudWatch alerts SNS topic"
  enable_key_rotation     = true
  deletion_window_in_days = 7 # 7 is the minimum AWS allows

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Without this the key becomes unmanageable - the same trap as the SNS
        # topic policy below.
        Sid       = "EnableAccountAdministration"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        # The statement the AWS-managed key is missing.
        Sid       = "AllowCloudWatchAlarmsToUseTheKey"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Resource  = "*"
      },
      {
        # SNS itself needs the key to decrypt on delivery.
        Sid       = "AllowSNSToUseTheKey"
        Effect    = "Allow"
        Principal = { Service = "sns.amazonaws.com" }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Resource  = "*"
      },
    ]
  })

  tags = { Name = "${local.name}-sns-key" }
}

resource "aws_kms_alias" "sns" {
  name          = "alias/${local.name}-sns"
  target_key_id = aws_kms_key.sns.key_id
}

resource "aws_sns_topic" "alerts" {
  name              = "${local.name}-alerts"
  kms_master_key_id = aws_kms_key.sns.id

  tags = { Name = "${local.name}-alerts" }
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---- Alarms ----------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "asg_high_cpu" {
  alarm_name          = "${local.name}-asg-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "Application tier average CPU above 70% for two minutes"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app.name
  }
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${local.name}-unhealthy-targets"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "One or more targets failing ALB health checks"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${local.name}-alb-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Load balancer returning 5xx responses"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${local.name}-rds-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Database CPU sustained above 80%"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  # .identifier, NOT .id. On aws_db_instance the `id` attribute is the DBI
  # RESOURCE id (db-FFVIESG6QV7...), while the CloudWatch dimension wants the
  # instance identifier (saa-capstone-mysql). Using `id` here is silent: the
  # alarm creates fine and then sits in INSUFFICIENT_DATA forever, because
  # that dimension value has no metrics behind it.
  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.identifier
  }
}

# Attaching a topic policy REPLACES the default one, which is what grants the
# account root full control. Both statements are therefore required: drop the
# owner statement and you can no longer manage your own topic.
resource "aws_sns_topic_policy" "allow_events" {
  arn = aws_sns_topic.alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowOwnerFullControl"
        Effect    = "Allow"
        Principal = { AWS = data.aws_caller_identity.current.account_id }
        Action = [
          "SNS:Publish", "SNS:Subscribe", "SNS:GetTopicAttributes",
          "SNS:SetTopicAttributes", "SNS:ListSubscriptionsByTopic",
          "SNS:AddPermission", "SNS:RemovePermission", "SNS:DeleteTopic",
        ]
        Resource = aws_sns_topic.alerts.arn
      },
      {
        Sid       = "AllowCloudWatchAlarmsToPublish"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.alerts.arn
        Condition = {
          StringEquals = { "AWS:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      },
    ]
  })
}

# ---- Dashboard -------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "ALB request count and 5xx"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.main.arn_suffix],
            [".", "HTTPCode_ELB_5XX_Count", ".", "."],
            [".", "HTTPCode_Target_5XX_Count", ".", "."]
          ]
          period = 60
          stat   = "Sum"
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "Auto Scaling Group CPU and capacity"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", aws_autoscaling_group.app.name],
            ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", aws_autoscaling_group.app.name, { yAxis = "right" }],
            ["AWS/AutoScaling", "GroupDesiredCapacity", "AutoScalingGroupName", aws_autoscaling_group.app.name, { yAxis = "right" }]
          ]
          period = 60
          stat   = "Average"
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "Target health"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", aws_lb.main.arn_suffix, "TargetGroup", aws_lb_target_group.app.arn_suffix],
            [".", "UnHealthyHostCount", ".", ".", ".", "."]
          ]
          period = 60
          stat   = "Average"
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "RDS - CPU, connections, free storage"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.main.identifier],
            [".", "DatabaseConnections", ".", "."],
            [".", "FreeStorageSpace", ".", ".", { yAxis = "right" }]
          ]
          period = 300
          stat   = "Average"
        }
      },
      {
        type = "metric", x = 0, y = 12, width = 24, height = 6
        properties = {
          title  = "WAF - allowed vs blocked requests"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["AWS/WAFV2", "AllowedRequests", "WebACL", aws_wafv2_web_acl.main.name, "Region", var.aws_region, "Rule", "ALL"],
            [".", "BlockedRequests", ".", ".", ".", ".", ".", "."]
          ]
          period = 60
          stat   = "Sum"
        }
      }
    ]
  })
}
