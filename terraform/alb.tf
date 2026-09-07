###############################################################################
# Application Load Balancer (Layer 7) + target group.
#
# No domain in Route 53 for this build, so the listener is HTTP:80 on the
# ALB's own DNS name. The HTTPS/ACM design is documented in the README as the
# production variant - see "Encryption in transit" there.
###############################################################################

resource "aws_lb" "main" {
  name               = "${local.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection = false
  enable_http2               = true
  idle_timeout               = 60

  # Drops malformed requests rather than forwarding them - defence in depth
  # alongside WAF, and a CIS control.
  drop_invalid_header_fields = true

  tags = { Name = "${local.name}-alb" }
}

resource "aws_lb_target_group" "app" {
  name     = "${local.name}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # Connection draining. An instance being scaled in finishes in-flight
  # requests instead of dropping them.
  deregistration_delay = 30

  stickiness {
    type            = "lb_cookie"
    cookie_duration = 3600
    enabled         = false
  }

  tags = { Name = "${local.name}-tg" }

  # Deliberately NO create_before_destroy here. Target group names must be
  # unique, and `name_prefix` on a target group is capped at 6 characters,
  # which would make the name unreadable. Without create_before_destroy
  # Terraform destroys the old group first, so a replacement succeeds.
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# Listener rule demonstrating path-based routing. /admin* returns a hard 403
# at the load balancer, so the request never reaches an instance at all -
# cheaper and safer than handling it in the application.
resource "aws_lb_listener_rule" "block_admin" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden - administrative paths are not exposed publicly."
      status_code  = "403"
    }
  }

  condition {
    path_pattern {
      values = ["/admin", "/admin/*"]
    }
  }
}
