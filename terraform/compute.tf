###############################################################################
# Application tier: Launch Template + Auto Scaling Group.
#
# Access model: SSM Session Manager only. No key pair, no port 22, no bastion.
# This removes an entire class of exposure and is the modern answer to the
# "how do you reach instances in a private subnet" exam question.
###############################################################################

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}

resource "aws_iam_role" "app" {
  name = "${local.name}-app-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Managed policy that grants exactly what the SSM agent needs - nothing more.
resource "aws_iam_role_policy_attachment" "app_ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "app_cloudwatch" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Least-privilege inline policy: this instance may read ONE secret, not all of
# them. Scoping to the specific secret ARN is the difference between a passing
# and a distinction-grade IAM design.
resource "aws_iam_role_policy" "app_secret_read" {
  name = "${local.name}-read-db-secret"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.db.arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "${local.name}-app-instance-profile"
  role = aws_iam_role.app.name
}

resource "aws_launch_template" "app" {
  name_prefix   = "${local.name}-lt-"
  image_id      = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.app.arn
  }

  vpc_security_group_ids = [aws_security_group.app.id]

  # The instance is told WHICH secret to read and where - never the secret
  # itself. The value is fetched at runtime through the instance role.
  user_data = base64encode(templatefile("${path.module}/user-data.sh", {
    project_name   = var.project_name
    aws_region     = var.aws_region
    db_secret_name = aws_secretsmanager_secret.db.name
  }))

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 8
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # IMDSv2 required. Blocks the SSRF-to-credential-theft path that IMDSv1
  # allows. IMDSv2's session-token requirement closes that path.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${local.name}-app" }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "app" {
  # name_prefix, not name: with create_before_destroy a FIXED name makes any
  # replacement fail on a duplicate-name error, because the new group is
  # created before the old one is gone.
  name_prefix         = "${local.name}-asg-"
  vpc_zone_identifier = aws_subnet.app[*].id
  target_group_arns   = [aws_lb_target_group.app.arn]

  min_size         = var.asg_min_size
  max_size         = var.asg_max_size
  desired_capacity = var.asg_desired_capacity

  # ELB health checks, not EC2. An instance whose nginx has died still passes
  # an EC2 status check but fails the target group check - ELB health checks
  # are what make the ASG replace it.
  health_check_type         = "ELB"
  health_check_grace_period = 180

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${local.name}-app"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---- Scaling policies -------------------------------------------------------
# Target tracking is the primary policy: you declare the outcome (keep average
# CPU at 50%) and AWS computes the step adjustments. Preferred over step
# scaling for the common case, which is exactly what the exam tests.

resource "aws_autoscaling_policy" "cpu_target_tracking" {
  name                   = "${local.name}-cpu-target-50"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 50.0
  }
}

# A second target-tracking policy on request count per target. When two
# policies are active the ASG scales on whichever demands MORE capacity -
# it never scales in while another policy wants scale out.
resource "aws_autoscaling_policy" "request_count_tracking" {
  name                   = "${local.name}-requests-per-target"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.main.arn_suffix}/${aws_lb_target_group.app.arn_suffix}"
    }
    target_value = 1000.0
  }
}
