###############################################################################
# Route 53 - alias record + health check.
#
# Gated on var.domain_name. With no registered domain these resources are
# simply not created (count = 0) and the application is reached on the ALB's
# own DNS name. The code is here because the routing design is part of the
# Project 1 brief even when it cannot be applied.
###############################################################################

locals {
  route53_enabled = var.domain_name != "" && var.hosted_zone_id != ""
}

# An ALIAS record, not a CNAME. Two reasons this matters:
#   1. ALIAS works at the zone apex (example.com); CNAME is illegal there.
#   2. ALIAS queries to AWS targets are free; CNAME lookups are billed.
resource "aws_route53_record" "app" {
  count   = local.route53_enabled ? 1 : 0
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = var.enable_cloudfront ? local.cloudfront_domain : aws_lb.main.dns_name
    zone_id                = var.enable_cloudfront ? local.cloudfront_zone_id : aws_lb.main.zone_id
    evaluate_target_health = !var.enable_cloudfront
  }
}

resource "aws_route53_health_check" "app" {
  count             = local.route53_enabled ? 1 : 0
  fqdn              = aws_lb.main.dns_name
  port              = 80
  type              = "HTTP"
  resource_path     = "/health"
  failure_threshold = 3
  request_interval  = 30

  tags = { Name = "${local.name}-health-check" }
}

###############################################################################
# The alarm on that health check has to live in us-east-1 (see versions.tf),
# and a CloudWatch alarm can only publish to an SNS topic in its OWN region.
# So when the primary region is not us-east-1 the alarm needs a topic there
# too. Both are gated on the same condition, so neither exists in the default
# no-domain build.
###############################################################################

# KMS keys are regional, so the us-east-1 topic needs its own key with the same
# CloudWatch grant. See the long note in monitoring.tf for why the AWS-managed
# alias/aws/sns key silently breaks alarm notifications.
resource "aws_kms_key" "sns_us_east_1" {
  count                   = local.route53_enabled ? 1 : 0
  provider                = aws.us_east_1
  description             = "${local.name} - encrypts the us-east-1 Route 53 alerts topic"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableAccountAdministration"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchAlarmsToUseTheKey"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Resource  = "*"
      },
      {
        Sid       = "AllowSNSToUseTheKey"
        Effect    = "Allow"
        Principal = { Service = "sns.amazonaws.com" }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Resource  = "*"
      },
    ]
  })

  tags = { Name = "${local.name}-sns-key-use1" }
}

resource "aws_sns_topic" "alerts_us_east_1" {
  count             = local.route53_enabled ? 1 : 0
  provider          = aws.us_east_1
  name              = "${local.name}-alerts-use1"
  kms_master_key_id = aws_kms_key.sns_us_east_1[0].id

  tags = { Name = "${local.name}-alerts-use1" }
}

resource "aws_sns_topic_subscription" "alerts_us_east_1_email" {
  count     = local.route53_enabled && var.alert_email != "" ? 1 : 0
  provider  = aws.us_east_1
  topic_arn = aws_sns_topic.alerts_us_east_1[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "route53_health" {
  count               = local.route53_enabled ? 1 : 0
  provider            = aws.us_east_1
  alarm_name          = "${local.name}-endpoint-unhealthy"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "Route 53 health check reporting the endpoint as down"
  alarm_actions       = [aws_sns_topic.alerts_us_east_1[0].arn]
  treat_missing_data  = "breaching"

  dimensions = {
    HealthCheckId = aws_route53_health_check.app[0].id
  }
}
