###############################################################################
# Security Groups - chained by SOURCE SECURITY GROUP, never by CIDR.
#
#   internet --> [alb-sg] --> [app-sg] --> [rds-sg]
#
# Referencing the source SG instead of a CIDR means the rule stays correct as
# instances scale in and out and IPs change. This is the pattern the SAA exam
# expects and the single most common review comment on capstone projects.
###############################################################################

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb-sg"
  description = "Public entry point. HTTP from the internet only."
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-alb-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from anywhere - WAF in front filters malicious requests"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to application tier only"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
}

# ------------------------------------------------------------- app tier -----

resource "aws_security_group" "app" {
  name        = "${local.name}-app-sg"
  description = "Application tier. Ingress ONLY from the ALB security group."
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-app-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "HTTP from the ALB only - no direct internet path exists"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
}

# NOTE: there is deliberately NO port 22 ingress rule anywhere in this project.
# Administrative access is via SSM Session Manager, which needs no inbound
# port, no key pair and no bastion host. See compute.tf.

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  description       = "Outbound via NAT for yum updates and the SSM agent"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ------------------------------------------------------------ data tier -----

resource "aws_security_group" "rds" {
  name        = "${local.name}-rds-sg"
  description = "Database tier. MySQL from the application tier only. No egress."
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-rds-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_app" {
  security_group_id            = aws_security_group.rds.id
  description                  = "MySQL 3306 from the application security group"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
}

# No egress rule on the RDS security group at all. The database never needs to
# initiate a connection outbound.
