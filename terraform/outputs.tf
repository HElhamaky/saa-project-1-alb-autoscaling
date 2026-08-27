output "application_url" {
  description = "Open this in a browser. Refresh a few times to see the ALB round-robin between AZs."
  value       = "http://${aws_lb.main.dns_name}"
}

output "alb_dns_name" {
  description = "ALB DNS name."
  value       = aws_lb.main.dns_name
}

output "cloudfront_url" {
  description = "CloudFront edge URL. Empty if enable_cloudfront = false."
  value       = var.enable_cloudfront ? "https://${local.cloudfront_domain}" : "(cloudfront disabled)"
}

output "site_url" {
  description = "Route 53 alias URL. Empty unless domain_name is configured."
  value       = local.route53_enabled ? "http://${var.domain_name}" : "(no domain configured - use application_url)"
}

output "rds_endpoint" {
  description = "RDS writer endpoint. Resolvable only from inside the VPC."
  value       = aws_db_instance.main.endpoint
}

output "rds_multi_az" {
  description = "Whether the database is deployed Multi-AZ."
  value       = aws_db_instance.main.multi_az
}

output "db_secret_name" {
  description = "Secrets Manager secret holding the master credentials."
  value       = aws_secretsmanager_secret.db.name
}

output "asg_name" {
  description = "Auto Scaling Group name - needed for the scaling demo commands."
  value       = aws_autoscaling_group.app.name
}

output "waf_web_acl" {
  description = "WAF Web ACL name."
  value       = aws_wafv2_web_acl.main.name
}

output "dashboard_url" {
  description = "CloudWatch dashboard."
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "demo_commands" {
  description = "Copy-paste commands for the evidence capture session."
  value       = <<-EOT

    ── Connect to an instance (no SSH key, no bastion) ──────────────────
    aws ssm start-session --target $(aws ec2 describe-instances \
      --filters "Name=tag:aws:autoscaling:groupName,Values=${aws_autoscaling_group.app.name}" \
                "Name=instance-state-name,Values=running" \
      --query 'Reservations[0].Instances[0].InstanceId' --output text)

    ── Trigger a scale-out (run inside the session above) ───────────────
    sudo /usr/local/bin/burn-cpu.sh 420

    ── Force an RDS Multi-AZ failover ───────────────────────────────────
    aws rds reboot-db-instance --db-instance-identifier ${aws_db_instance.main.identifier} --force-failover

    ── Prove CloudFront caches static assets but not dynamic HTML ───────
    # dynamic: x-cache should say "Miss from cloudfront" every time
    curl -sI ${local.public_base_url}/ | grep -i "x-cache"
    # static: run TWICE - second call should say "Hit from cloudfront"
    curl -sI ${local.public_base_url}/static/logo.svg | grep -i "x-cache"

    ── Prove the app tier actually reaches the Multi-AZ database ────────
    # expect: OK  endpoint=...  server=<hostname> 8.0.x 0  tls=enforced
    curl -s http://${aws_lb.main.dns_name}/dbstatus.txt
    # after a forced failover the server hostname changes - run it again

    ── Prove WAF blocks SQL injection ───────────────────────────────────
    curl -i "http://${aws_lb.main.dns_name}/?id=1%27%20OR%20%271%27=%271"

    ── Prove the ALB listener rule blocks /admin ────────────────────────
    curl -i "http://${aws_lb.main.dns_name}/admin"

    ── Read the DB password from Secrets Manager ────────────────────────
    aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.db.name} \
      --query SecretString --output text

  EOT
}
